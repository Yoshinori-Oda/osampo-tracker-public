enum MoveMethod {
  walk,
  run,
  bicycle,
  car,
  train,
  plane,
  ship,
  ;

  static MoveMethod fromString(String? value) {
    if (value == null) return MoveMethod.walk;
    return MoveMethod.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MoveMethod.walk,
    );
  }

  String get label {
    switch (this) {
      case MoveMethod.walk:
        return '徒歩';
      case MoveMethod.run:
        return 'ランニング';
      case MoveMethod.bicycle:
        return 'サイクリング';
      case MoveMethod.car:
        return 'ドライブ';
      case MoveMethod.train:
        return '電車';
      case MoveMethod.plane:
        return '飛行機';
      case MoveMethod.ship:
        return '船';
    }
  }
}

