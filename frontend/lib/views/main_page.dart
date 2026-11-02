import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/recording_phase.dart';
import '../providers/auth_providers.dart';
import '../providers/tracking_providers.dart';
import '../widgets/auth_banner_view.dart';
import '../widgets/location_banner_view.dart';
import '../widgets/recording_phase_banner_view.dart';
import 'recording_page.dart';
import 'saved_sessions.dart';
import 'analytics_page.dart';
import 'settings_page.dart';

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // アプリ起動時に一度、メールアドレスの確認状態を取り込んでから、他端末での変更を取り込む
    _refreshProfileAndSync();
    // 初回フレーム描画後(ダイアログ表示に必要なNavigatorのmoutを待ってから)、
    // クラッシュ等で保存/破棄されないまま残ったセッションがないか確認する
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(trackingServiceProvider).recoverOrphanedSessions();
    });
  }

  Future<void> _refreshProfileAndSync() async {
    await ref.read(authControllerProvider.notifier).refreshProfile();
    if (!mounted) return;
    ref.read(repositoryProvider).requestSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // バックグラウンドから復帰した際にも同期しておく
    if (state == AppLifecycleState.resumed) {
      _refreshProfileAndSync();
    }
    // 収録中でなければバックグラウンドで位置情報の購読を止め、復帰時に再開する。
    // 復帰時は、設定アプリでの位置情報サービス/権限の変更がストリームのonErrorだけでは
    // 検知できないため、明示的な再チェック(refreshLocationAvailability)もここから行われる
    ref.read(trackingServiceProvider).handleAppLifecycleState(state);
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(bottomNavIndexProvider);

    // 同期できない状態から戻ったら(再ログイン・メールアドレスの確認)、止まっていた同期を再開する
    ref.listen<bool>(authControllerProvider.select((auth) => auth.value?.canSync ?? false), (previous, next) {
      if (previous == false && next) ref.read(repositoryProvider).requestSync();
    });

    // バナーが1つも表示されない間はSafeAreaの上部paddingも含めてスペースを確保しない
    final locationBannerActive = ref.watch(locationBannerProvider).value?.isActive ?? false;
    final recordingPhase = ref.watch(recordingPhaseProvider).value ?? RecordingPhase.idle;
    final authBannerActive = AuthBannerView.isActive(ref.watch(authControllerProvider).value);
    final hasAnyBanner = locationBannerActive || recordingPhase != RecordingPhase.idle || authBannerActive;

    final pages = [
      const RecordingPage(),
      Navigator(
        key: GlobalKey<NavigatorState>(),
        onGenerateRoute: (routeSettings) {
          return MaterialPageRoute(builder: (context) => SavedSessionsView());
        }
      ),
      const AnalyticsPage(),
      const SettingsPage(),
    ];

    // バナーの分だけステータスバー避けのpaddingを上に1回だけ充てる。
    // 下のタブ側(各AppBar)には二重にpaddingがかからないよう、ここで消費しておく
    final topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(top: hasAnyBanner ? topInset : 0),
            child: Column(
              children: [
                const RecordingPhaseBannerView(),
                const LocationBannerView(),
                const AuthBannerView()
              ]
            )
          ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: hasAnyBanner,
              child: IndexedStack(
                index: currentIndex,
                children: pages
              )
            )
          )
        ]
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (index) {
          ref.read(bottomNavIndexProvider.notifier).setIndex(index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_fill),
            label: '収録'
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_run_outlined),
            selectedIcon: Icon(Icons.directions_run),
            label: '履歴'
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: '統計'
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: '設定'
          )
        ]
      )
    );
  }
}