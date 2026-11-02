import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test_tracking_01/auth/auth_service.dart';
import 'package:test_tracking_01/auth/auth_storage.dart';
import 'package:test_tracking_01/auth/authorized_client.dart';
import 'package:test_tracking_01/database/app_database.dart';
import 'package:test_tracking_01/models/status.dart';
import 'package:test_tracking_01/providers/auth_providers.dart';
import 'package:test_tracking_01/widgets/auth_banner_view.dart';

// 認証(AuthService・AuthorizedClient)がbackend/docs/API設計ドラフト.mdの「認証のendpoints」を
// frontend/docs/ユーザー機能追加に伴う変更予定.mdの「認証(ブロック2)」の約束どおりに呼ぶことの確認

const _userId = '11111111-1111-1111-1111-111111111111';
const _baseUrl = 'http://test/api';
const _deviceId = '33333333-3333-3333-3333-333333333333';

class _MemoryAuthStorage implements AuthStorage {
  // 通常のアカウントの今のユーザーとトークン
  StoredAuth? stored;
  // トークン無しで保存した今のユーザー(ローカルアカウント)
  String? localUserId;

  @override
  Future<String> deviceId() async => _deviceId;

  @override
  Future<StoredAuth?> read() async => stored;

  @override
  Future<String?> readCurrentUserId() async => stored?.userId ?? localUserId;

  @override
  Future<void> save(StoredAuth auth) async {
    stored = auth;
    localUserId = null;
  }

  @override
  Future<void> saveLocalUser(String userId) async {
    stored = null;
    localUserId = userId;
  }

  @override
  Future<void> clear() async {
    stored = null;
    localUserId = null;
  }
}

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(int status, String code) => _json(status, {'code': code, 'message': code});

Map<String, dynamic> _user({bool emailVerified = true}) => {
  'id': _userId,
  'email': 'test@example.com',
  'display_name': 'テスト',
  'email_verified': emailVerified,
  'role': 'user',
  'created_at': '2026-10-01T00:00:00Z',
};

Map<String, dynamic> _tokens(String suffix, {bool emailVerified = true}) => {
  'access_token': 'access-$suffix',
  'refresh_token': 'refresh-$suffix',
  'token_type': 'Bearer',
  'expires_in': 900,
  'user': _user(emailVerified: emailVerified),
};

void main() {
  late AppDatabase db;
  late _MemoryAuthStorage storage;
  late List<http.Request> requests;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryAuthStorage();
    requests = [];
  });

  tearDown(() => db.close());

  AuthService createService(Future<http.Response> Function(http.Request request) handler) {
    final service = AuthService(
      db,
      storage,
      client: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
      baseUrl: _baseUrl,
    );
    addTearDown(service.dispose);
    return service;
  }

  Future<void> signIn(AuthService service) async {
    await db.upsertUser(id: _userId, email: 'test@example.com', displayName: 'テスト', emailVerified: true);
    storage.stored = const StoredAuth(userId: _userId, accessToken: 'access-0', refreshToken: 'refresh-0');
    await service.restore();
  }

  group('login・signup', () {
    test('ログインすると端末IDを付けて送り、ユーザーの行とトークンを保存する', () async {
      final service = createService((_) async => _json(200, _tokens('1', emailVerified: false)));

      final result = await service.login(email: 'test@example.com', password: 'password1');

      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(requests.single.url.path, '/api/auth/login');
      expect(body, {'email': 'test@example.com', 'password': 'password1', 'device_id': _deviceId});
      expect(result.userId, _userId);
      expect(result.emailVerified, isFalse);
      expect(storage.stored!.accessToken, 'access-1');
      expect(service.userId, _userId);
      final user = (await db.getUser(_userId))!;
      expect(user.email, 'test@example.com');
      expect(user.emailVerified, isFalse);
    });

    test('新規登録で表示名が空なら送らない(サーバーがメールアドレスの@より前にする)', () async {
      final service = createService((_) async => _json(201, _tokens('1')));

      await service.signup(email: 'test@example.com', password: 'password1', displayName: '  ');

      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(requests.single.url.path, '/api/auth/signup');
      expect(body.containsKey('display_name'), isFalse);
    });

    test('エラーはcodeをAuthExceptionにして投げ、何も保存しない', () async {
      final service = createService((_) async => _error(401, 'invalid_credentials'));

      await expectLater(
        service.login(email: 'test@example.com', password: 'wrong-password'),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'invalid_credentials')),
      );
      expect(storage.stored, isNull);
      expect(await db.getUser(_userId), isNull);
    });

    test('試行回数の上限(429)はRetry-Afterの秒数をAuthExceptionに入れる', () async {
      final service = createService((_) async => http.Response(
        jsonEncode({'code': 'too_many_requests', 'message': 'too_many_requests'}),
        429,
        headers: {'content-type': 'application/json', 'retry-after': '600'},
      ));

      await expectLater(
        service.login(email: 'test@example.com', password: 'password'),
        throwsA(isA<AuthException>()
          .having((e) => e.code, 'code', 'too_many_requests')
          .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 600)),
      );
    });

    test('通信できなければnetworkのAuthExceptionを投げる', () async {
      final service = createService((_) async => throw http.ClientException('offline'));

      await expectLater(
        service.login(email: 'test@example.com', password: 'password1'),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', AuthException.network)),
      );
    });
  });

  group('refreshTokens', () {
    test('同時に呼ばれても通信は1回にまとめ、新しいトークンを保存する', () async {
      final completer = Completer<http.Response>();
      final service = createService((_) => completer.future);
      await signIn(service);

      final first = service.refreshTokens();
      final second = service.refreshTokens();
      completer.complete(_json(200, _tokens('2')));

      expect(await first, RefreshOutcome.refreshed);
      expect(await second, RefreshOutcome.refreshed);
      expect(requests, hasLength(1));
      expect(jsonDecode(requests.single.body), {'refresh_token': 'refresh-0'});
      expect(storage.stored!.refreshToken, 'refresh-2');
      expect(service.accessToken, 'access-2');
    });

    test('401はrejected(再ログインが必要)、通信できなければfailed(ログイン状態はそのまま)', () async {
      var response = _error(401, 'invalid_refresh_token');
      final service = createService((_) async => response);
      await signIn(service);

      expect(await service.refreshTokens(), RefreshOutcome.rejected);

      response = _error(503, 'service_unavailable');
      expect(await service.refreshTokens(), RefreshOutcome.failed);
      expect(storage.stored!.refreshToken, 'refresh-0');
    });
  });

  group('logout・deleteAccount', () {
    test('ログアウトはサーバーが失敗してもトークンを消し、ローカルのデータは残す', () async {
      final service = createService((_) async => throw http.ClientException('offline'));
      await signIn(service);
      final apiRequests = <http.Request>[];
      final client = AuthorizedClient(service, inner: MockClient((request) async {
        apiRequests.add(request);
        throw http.ClientException('offline');
      }));

      await service.logout(client);

      expect(apiRequests.single.url.path, '/api/auth/logout');
      expect(apiRequests.single.headers['Authorization'], 'Bearer access-0');
      expect(storage.stored, isNull);
      expect(service.userId, isNull);
      expect(await db.getUser(_userId), isNotNull);
    });

    test('アクセストークンが期限切れなら、トークンを更新してからログアウトし、トークンを消す', () async {
      final service = createService((_) async => _json(200, _tokens('2')));
      await signIn(service);
      final apiRequests = <http.Request>[];
      final client = AuthorizedClient(service, inner: MockClient((request) async {
        apiRequests.add(request);
        return request.headers['Authorization'] == 'Bearer access-2'
          ? http.Response('', 204)
          : _error(401, 'token_expired');
      }));

      await service.logout(client);

      expect(requests.single.url.path, '/api/auth/refresh');
      expect(apiRequests.map((r) => r.url.path), ['/api/auth/logout', '/api/auth/logout']);
      expect(apiRequests.map((r) => r.headers['Authorization']), ['Bearer access-0', 'Bearer access-2']);
      expect(storage.stored, isNull);
      expect(service.userId, isNull);
    });

    test('トークンの更新も拒否されたら(サーバーのログイン状態は無効)、送り直さずにトークンを消す', () async {
      final service = createService((_) async => _error(401, 'invalid_refresh_token'));
      await signIn(service);
      final apiRequests = <http.Request>[];
      final client = AuthorizedClient(service, inner: MockClient((request) async {
        apiRequests.add(request);
        return _error(401, 'token_expired');
      }));

      await service.logout(client);

      expect(requests.single.url.path, '/api/auth/refresh');
      expect(apiRequests, hasLength(1));
      expect(storage.stored, isNull);
      expect(service.userId, isNull);
      expect(await db.getUser(_userId), isNotNull);
    });

    test('アカウントの削除に成功したら、そのユーザーのローカルのデータも消す', () async {
      final service = createService((_) async => http.Response('', 204));
      await signIn(service);
      final client = AuthorizedClient(service, inner: MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      }));

      await service.deleteAccount(client);

      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.path, '/api/users/me');
      expect(await db.getUser(_userId), isNull);
      expect(storage.stored, isNull);
    });

    test('アカウントの削除に失敗したら、何も消さずにAuthExceptionを投げる', () async {
      final service = createService((_) async => http.Response('', 204));
      await signIn(service);
      final client = AuthorizedClient(service, inner: MockClient((_) async => _error(500, 'internal_error')));

      await expectLater(
        service.deleteAccount(client),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'internal_error')),
      );
      expect(await db.getUser(_userId), isNotNull);
      expect(storage.stored, isNotNull);
    });

    // 前回の削除がサーバーでは済んだのに結果が届かなかった場合、押し直すとログイン状態もユーザーも無いので401になる
    test('アカウントの削除が401(unauthenticated)なら、削除済みとみなしてローカルのデータも消す', () async {
      final service = createService((_) async => http.Response('', 204));
      await signIn(service);
      final client = AuthorizedClient(service, inner: MockClient((_) async => _error(401, 'unauthenticated')));

      await service.deleteAccount(client);

      expect(await db.getUser(_userId), isNull);
      expect(storage.stored, isNull);
      expect(service.userId, isNull);
    });

    test('アクセストークンが期限切れで、トークンの更新も拒否されたら、削除済みとみなしてローカルのデータも消す', () async {
      final service = createService((_) async => _error(401, 'invalid_refresh_token'));
      await signIn(service);
      final client = AuthorizedClient(service, inner: MockClient((_) async => _error(401, 'token_expired')));

      await service.deleteAccount(client);

      expect(requests.single.url.path, '/api/auth/refresh');
      expect(await db.getUser(_userId), isNull);
      expect(storage.stored, isNull);
    });

    test('トークンの更新が通信できずに失敗したら、何も消さずにnetworkのAuthExceptionを投げる', () async {
      final service = createService((_) async => throw http.ClientException('offline'));
      await signIn(service);
      final client = AuthorizedClient(service, inner: MockClient((_) async => _error(401, 'token_expired')));

      await expectLater(
        service.deleteAccount(client),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', AuthException.network)),
      );
      expect(await db.getUser(_userId), isNotNull);
      expect(storage.stored, isNotNull);
    });
  });

  group('メールアドレスの確認コード', () {
    // AuthorizedClient経由で、決まったレスポンスを返す(Bearerが付くことも確かめる)
    Future<AuthService> signedInService() async {
      final service = createService((_) async => http.Response('', 500));
      await db.upsertUser(id: _userId, email: 'test@example.com', displayName: 'テスト', emailVerified: false);
      storage.stored = const StoredAuth(userId: _userId, accessToken: 'access-0', refreshToken: 'refresh-0');
      await service.restore();
      return service;
    }

    AuthorizedClient clientReturning(AuthService service, http.Response response) =>
      AuthorizedClient(service, inner: MockClient((request) async {
        requests.add(request);
        return response;
      }));

    test('再発行は202なら次に再発行できるまでの秒数を返す', () async {
      final service = await signedInService();
      final client = clientReturning(service, _json(202, {'expires_in': 600, 'resend_available_in': 60}));

      expect(await service.sendVerificationCode(client), 60);
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/api/users/me/email-verification');
      expect(requests.single.headers['Authorization'], 'Bearer access-0');
    });

    test('再発行の429はRetry-Afterの秒数をAuthExceptionに入れる', () async {
      final service = await signedInService();
      final client = clientReturning(service, http.Response(
        jsonEncode({'code': 'too_many_requests', 'message': '...'}),
        429,
        headers: {'content-type': 'application/json', 'retry-after': '42'},
      ));

      await expectLater(
        service.sendVerificationCode(client),
        throwsA(isA<AuthException>()
          .having((e) => e.code, 'code', 'too_many_requests')
          .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 42)),
      );
    });

    test('再発行の409は確認済みとしてAuthExceptionを投げる', () async {
      final service = await signedInService();
      final client = clientReturning(service, _error(409, 'email_already_verified'));

      await expectLater(
        service.sendVerificationCode(client),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'email_already_verified')),
      );
    });

    test('確認に成功したら、端末のユーザーを確認済みにする', () async {
      final service = await signedInService();
      final client = clientReturning(service, _json(200, _user(emailVerified: true)));

      await service.confirmVerificationCode(client, '012345');

      expect(requests.single.url.path, '/api/users/me/email-verification/confirm');
      expect(jsonDecode(requests.single.body), {'code': '012345'});
      expect((await db.getUser(_userId))!.emailVerified, isTrue);
    });

    for (final (status, code) in [
      (400, 'invalid_verification_code'),
      (400, 'verification_code_expired'),
      (422, 'validation_error'),
    ]) {
      test('確認の$status($code)はAuthExceptionを投げ、端末のユーザーは未確認のまま', () async {
        final service = await signedInService();
        final client = clientReturning(service, _error(status, code));

        await expectLater(
          service.confirmVerificationCode(client, '999999'),
          throwsA(isA<AuthException>().having((e) => e.code, 'code', code)),
        );
        expect((await db.getUser(_userId))!.emailVerified, isFalse);
      });
    }

    test('通信できなければnetworkのAuthExceptionを投げる', () async {
      final service = await signedInService();
      final client = AuthorizedClient(service, inner: MockClient((_) async => throw http.ClientException('offline')));

      await expectLater(
        service.sendVerificationCode(client),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', AuthException.network)),
      );
    });
  });

  group('パスワード・表示名の変更', () {
    AuthorizedClient clientReturning(AuthService service, http.Response response) =>
      AuthorizedClient(service, inner: MockClient((request) async {
        requests.add(request);
        return response;
      }));

    test('パスワードの変更は現在と新しいパスワードをPUTで送る', () async {
      final service = createService((_) async => http.Response('', 500));
      await signIn(service);
      final client = clientReturning(service, http.Response('', 204));

      await service.changePassword(client, currentPassword: 'old-password', newPassword: 'new-password');

      expect(requests.single.method, 'PUT');
      expect(requests.single.url.path, '/api/users/me/password');
      expect(jsonDecode(requests.single.body), {'current_password': 'old-password', 'new_password': 'new-password'});
      // この端末はログインしたまま
      expect(storage.stored, isNotNull);
    });

    test('現在のパスワードが違えば(400)AuthExceptionを投げる', () async {
      final service = createService((_) async => http.Response('', 500));
      await signIn(service);
      final client = clientReturning(service, _error(400, 'invalid_current_password'));

      await expectLater(
        service.changePassword(client, currentPassword: 'wrong', newPassword: 'new-password'),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'invalid_current_password')),
      );
      // 401ではないので、ログイン状態は無効にならない
      expect(storage.stored, isNotNull);
    });

    test('現在のパスワードの試行回数の上限(429)はRetry-Afterの秒数をAuthExceptionに入れる', () async {
      final service = createService((_) async => http.Response('', 500));
      await signIn(service);
      final client = clientReturning(service, http.Response(
        jsonEncode({'code': 'too_many_requests', 'message': 'too_many_requests'}),
        429,
        headers: {'content-type': 'application/json', 'retry-after': '900'},
      ));

      await expectLater(
        service.changePassword(client, currentPassword: 'old-password', newPassword: 'new-password'),
        throwsA(isA<AuthException>()
          .having((e) => e.code, 'code', 'too_many_requests')
          .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 900)),
      );
      expect(storage.stored, isNotNull);
    });

    test('表示名の変更に成功したら、端末のユーザーにも書く', () async {
      final service = createService((_) async => http.Response('', 500));
      await signIn(service);
      final client = clientReturning(service, _json(200, {..._user(), 'display_name': 'たろう'}));

      await service.updateDisplayName(client, 'たろう');

      expect(requests.single.method, 'PATCH');
      expect(jsonDecode(requests.single.body), {'display_name': 'たろう'});
      expect((await db.getUser(_userId))!.displayName, 'たろう');
    });
  });

  group('AuthorizedClient', () {
    test('Bearerを付け、401(token_expired)ならトークンを更新して1回だけやり直す', () async {
      final service = createService((_) async => _json(200, _tokens('2')));
      await signIn(service);
      final apiRequests = <http.Request>[];
      final client = AuthorizedClient(service, inner: MockClient((request) async {
        apiRequests.add(request);
        return request.headers['Authorization'] == 'Bearer access-2'
          ? _json(200, {'ok': true})
          : _error(401, 'token_expired');
      }));

      final response = await client.post(Uri.parse('$_baseUrl/users/$_userId/sessions'), body: '{"id":"s1"}');

      expect(response.statusCode, 200);
      expect(apiRequests.map((r) => r.headers['Authorization']), ['Bearer access-0', 'Bearer access-2']);
      // やり直しでもbodyを同じに送る
      expect(apiRequests.last.body, '{"id":"s1"}');
      expect(requests.single.url.path, '/api/auth/refresh');
    });

    test('トークンの更新が拒否されたら、onAuthInvalidを呼んで401を返す', () async {
      final service = createService((_) async => _error(401, 'invalid_refresh_token'));
      await signIn(service);
      var invalidated = 0;
      final client = AuthorizedClient(
        service,
        inner: MockClient((_) async => _error(401, 'token_expired')),
        onAuthInvalid: () => invalidated++,
      );

      final response = await client.get(Uri.parse('$_baseUrl/users/me'));

      expect(response.statusCode, 401);
      expect(jsonDecode(response.body)['code'], 'token_expired');
      expect(invalidated, 1);
    });

    test('トークンの更新が通信できずに失敗したら、onAuthInvalidは呼ばずに通信の失敗として例外を投げる(次の機会に再び試す)', () async {
      final service = createService((_) async => throw http.ClientException('offline'));
      await signIn(service);
      var invalidated = 0;
      final client = AuthorizedClient(
        service,
        inner: MockClient((_) async => _error(401, 'token_expired')),
        onAuthInvalid: () => invalidated++,
      );

      await expectLater(client.get(Uri.parse('$_baseUrl/users/me')), throwsA(isA<http.ClientException>()));
      expect(invalidated, 0);
      expect(storage.stored!.accessToken, 'access-0');
    });

    test('token_expired以外の401(ログアウト済み等)は更新せずにonAuthInvalidを呼ぶ', () async {
      final service = createService((_) async => _json(200, _tokens('2')));
      await signIn(service);
      var invalidated = 0;
      final client = AuthorizedClient(
        service,
        inner: MockClient((_) async => _error(401, 'unauthenticated')),
        onAuthInvalid: () => invalidated++,
      );

      final response = await client.get(Uri.parse('$_baseUrl/users/me'));

      expect(response.statusCode, 401);
      expect(invalidated, 1);
      expect(requests, isEmpty);
    });

    test('403(email_not_verified)ならonEmailNotVerifiedを呼び、レスポンスはそのまま返す', () async {
      final service = createService((_) async => _json(200, _tokens('2')));
      await signIn(service);
      var notVerified = 0;
      final client = AuthorizedClient(
        service,
        inner: MockClient((_) async => _error(403, 'email_not_verified')),
        onEmailNotVerified: () => notVerified++,
      );

      final response = await client.get(Uri.parse('$_baseUrl/users/$_userId/sessions'));

      expect(response.statusCode, 403);
      expect(jsonDecode(response.body)['code'], 'email_not_verified');
      expect(notVerified, 1);
    });
  });

  group('ローカルアカウント', () {
    const localId = '44444444-4444-4444-4444-444444444444';

    Future<void> insertSession(String id, Status status, String userId) async {
      await db.into(db.sessions).insert(SessionsCompanion.insert(
        id: id,
        userId: userId,
        startedAt: DateTime.utc(2026, 10, 1, 8),
        status: Value(status),
      ));
    }

    Future<Map<String, (String, Status)>> sessionsById() async => {
      for (final session in await db.select(db.sessions).get()) session.id: (session.userId, session.status),
    };

    // ローカルアカウントで入った状態にする
    Future<AuthService> enterLocal(Future<http.Response> Function(http.Request request) handler) async {
      await db.createLocalUser(id: localId, displayName: 'ローカル');
      storage.localUserId = localId;
      final service = createService(handler);
      await service.restore();
      return service;
    }

    test('端末にユーザーがいない(初回起動)なら、ローカルアカウントを作って入る', () async {
      final service = createService((_) async => throw StateError('no request expected'));

      final userId = await service.restore();

      expect(userId, isNotNull);
      expect(service.isLocal, isTrue);
      expect(service.accessToken, isNull);
      expect(storage.localUserId, userId);
      final user = (await db.getUser(userId!))!;
      expect(user.isLocal, isTrue);
      expect(user.displayName, AuthService.defaultLocalDisplayName);
      expect(requests, isEmpty);
    });

    test('端末にユーザーがいて今のユーザーが無ければ(ログアウトした後)、作らずに未ログインにする', () async {
      await db.upsertUser(id: _userId, email: 'test@example.com', displayName: 'テスト', emailVerified: true);
      final service = createService((_) async => throw StateError('no request expected'));

      expect(await service.restore(), isNull);

      expect((await db.select(db.users).get()).map((user) => user.id), [_userId]);
    });

    test('ローカルアカウントはトークンが無くても復元する', () async {
      final service = await enterLocal((_) async => throw StateError('no request expected'));

      expect(service.userId, localId);
      expect(service.isLocal, isTrue);
    });

    test('通常のアカウントでトークンが無ければ、未ログインにして今のユーザーを消す', () async {
      await db.upsertUser(id: _userId, email: 'test@example.com', displayName: 'テスト', emailVerified: true);
      storage.localUserId = _userId;
      final service = createService((_) async => throw StateError('no request expected'));

      expect(await service.restore(), isNull);

      expect(await storage.readCurrentUserId(), isNull);
      expect(await db.getUser(_userId), isNotNull);
    });

    test('ローカルアカウントを削除すると記録も消え、今のユーザーなら未ログインになる。通常のアカウントは消さない', () async {
      final service = await enterLocal((_) async => throw StateError('no request expected'));
      await insertSession('l1', Status.ended, localId);
      await db.upsertUser(id: _userId, email: 'test@example.com', displayName: 'テスト', emailVerified: true);

      await service.deleteLocalAccount(_userId);
      await service.deleteLocalAccount(localId);

      expect(await db.getUser(localId), isNull);
      expect(await sessionsById(), isEmpty);
      expect(await db.getUser(_userId), isNotNull);
      expect(service.userId, isNull);
      expect(await storage.readCurrentUserId(), isNull);
    });

    test('通常のアカウントでログイン中は、ローカルアカウントに切り替えられない(先にログアウトする)', () async {
      await db.createLocalUser(id: localId, displayName: 'ローカル');
      final service = createService((_) async => throw StateError('no request expected'));
      await signIn(service);

      await expectLater(service.switchToLocalAccount(localId), throwsStateError);
      expect(storage.stored, isNotNull);
    });

    test('新規登録して記録を移すと、記録を未登録(ended)にして移し、ローカルアカウントを消す', () async {
      final service = await enterLocal((_) async => _json(201, _tokens('1', emailVerified: false)));
      await insertSession('l1', Status.updated, localId);
      await insertSession('l2', Status.synced, localId);
      await insertSession('l3', Status.deletedUnsynced, localId);
      await insertSession('recording', Status.inProgress, localId);

      final result = await service.signup(email: 'test@example.com', password: 'password1', mergeLocalAccount: true);

      expect(result.userId, _userId);
      expect(await sessionsById(), {
        'l1': (_userId, Status.ended),
        'l2': (_userId, Status.ended),
        'recording': (_userId, Status.inProgress),
      });
      expect(await db.getUser(localId), isNull);
      expect((await db.getUser(_userId))!.isLocal, isFalse);
      expect(storage.stored!.userId, _userId);
      expect(service.isLocal, isFalse);
      expect(service.accessToken, 'access-1');
    });

    test('ログインして記録を移すと、端末に既にあるそのアカウントの記録・同期の基準時刻と合わさる', () async {
      final service = await enterLocal((_) async => _json(200, _tokens('1')));
      await db.upsertUser(id: _userId, email: 'test@example.com', displayName: 'テスト', emailVerified: true);
      await db.setLastSyncedAt(_userId, '2026-10-01T00:00:00Z');
      await insertSession('n1', Status.synced, _userId);
      await insertSession('l1', Status.ended, localId);

      await service.login(email: 'test@example.com', password: 'password1', mergeLocalAccount: true);

      expect(await sessionsById(), {'n1': (_userId, Status.synced), 'l1': (_userId, Status.ended)});
      expect(await db.getLastSyncedAt(_userId), '2026-10-01T00:00:00Z');
      expect(await db.getUser(localId), isNull);
    });

    test('サーバーのIDが端末の別のローカルアカウントと重なったら、そのローカルアカウントのIDを変えて残す', () async {
      final service = await enterLocal((_) async => _json(200, _tokens('1')));
      await db.createLocalUser(id: _userId, displayName: '別のローカル');
      await insertSession('other', Status.ended, _userId);
      await insertSession('l1', Status.ended, localId);

      await service.login(email: 'test@example.com', password: 'password1', mergeLocalAccount: true);

      expect((await db.getUser(_userId))!.isLocal, isFalse);
      final others = (await db.select(db.users).get()).where((user) => user.isLocal).toList();
      expect(others.single.displayName, '別のローカル');
      expect(others.single.id, isNot(_userId));
      final sessions = await sessionsById();
      expect(sessions['other']!.$1, others.single.id);
      expect(sessions['l1']!.$1, _userId);
    });

    test('ログイン・新規登録が失敗したら、ローカルアカウントのまま何も変えない', () async {
      final service = await enterLocal((_) async => _error(409, 'email_already_registered'));
      await insertSession('l1', Status.ended, localId);

      await expectLater(
        service.signup(email: 'test@example.com', password: 'password1', mergeLocalAccount: true),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'email_already_registered')),
      );

      expect(await sessionsById(), {'l1': (localId, Status.ended)});
      expect(service.userId, localId);
      expect(service.isLocal, isTrue);
      expect(storage.localUserId, localId);
    });

    test('ローカルアカウントで入っていなければ、記録を移すログインはできない', () async {
      final service = createService((_) async => _json(200, _tokens('1')));
      await signIn(service);

      await expectLater(
        service.login(email: 'test@example.com', password: 'password1', mergeLocalAccount: true),
        throwsStateError,
      );
      expect(requests, isEmpty);
    });

    group('通常→ローカル', () {
      Future<AuthService> signInWithSessions() async {
        final service = createService((_) async => throw StateError('no request expected'));
        await signIn(service);
        await db.setLastSyncedAt(_userId, '2026-10-01T00:00:00Z');
        await insertSession('s1', Status.synced, _userId);
        await insertSession('s2', Status.updated, _userId);
        await insertSession('s3', Status.deletedUnsynced, _userId);
        await insertSession('recording', Status.inProgress, _userId);
        return service;
      }

      for (final (status, code) in [(204, null), (401, 'unauthenticated')]) {
        test('サーバーのアカウントの削除が$statusなら、IDはそのままでローカルアカウントにし、記録を残す', () async {
          final service = await signInWithSessions();
          final apiRequests = <http.Request>[];
          final client = AuthorizedClient(service, inner: MockClient((request) async {
            apiRequests.add(request);
            return code == null ? http.Response('', status) : _error(status, code);
          }));

          await service.convertToLocal(client);

          expect(apiRequests.single.method, 'DELETE');
          expect(apiRequests.single.url.path, '/api/users/me');
          final user = (await db.getUser(_userId))!;
          expect(user.isLocal, isTrue);
          expect(user.email, '');
          expect(user.emailVerified, isFalse);
          expect(user.lastSyncedAt, isNull);
          expect(await sessionsById(), {
            's1': (_userId, Status.ended),
            's2': (_userId, Status.ended),
            'recording': (_userId, Status.inProgress),
          });
          expect(storage.stored, isNull);
          expect(storage.localUserId, _userId);
          expect(service.userId, _userId);
          expect(service.isLocal, isTrue);
          expect(service.accessToken, isNull);
        });
      }

      test('サーバーのアカウントを削除できなければ、何も変えずにAuthExceptionを投げる', () async {
        final service = await signInWithSessions();
        final client = AuthorizedClient(service, inner: MockClient((_) async => _error(500, 'internal_error')));

        await expectLater(
          service.convertToLocal(client),
          throwsA(isA<AuthException>().having((e) => e.code, 'code', 'internal_error')),
        );

        expect((await db.getUser(_userId))!.isLocal, isFalse);
        expect((await sessionsById())['s1'], (_userId, Status.synced));
        expect(storage.stored, isNotNull);
        expect(service.isLocal, isFalse);
      });
    });

    test('ローカルアカウントは同期せず、メールアドレスが未確認でもバナーを出さない', () {
      const local = AuthState(userId: localId, isLocal: true);
      expect(local.canSync, isFalse);
      expect(AuthBannerView.isActive(local), isFalse);
      // メールアドレスが確認済みでも、ローカルアカウントなら同期しない
      expect(const AuthState(userId: localId, emailVerified: true, isLocal: true).canSync, isFalse);
      expect(const AuthState(userId: _userId, emailVerified: true).canSync, isTrue);
      expect(AuthBannerView.isActive(const AuthState(userId: _userId)), isTrue);
    });
  });
}
