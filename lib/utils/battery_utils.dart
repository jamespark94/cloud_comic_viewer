class BatteryUtils {
  /// 기기가 현재 절전 모드(Power Save Mode)인지 여부 반환
  static Future<bool> isPowerSaveMode() async {
    return false;
  }

  /// 앱이 배터리 최적화 예외(제한 없음)로 설정되어 있는지 여부 반환
  static Future<bool> isIgnoringBatteryOptimizations() async {
    return true;
  }

  /// 배터리 사용량 제한 없음 시스템 대화상자 요청
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    return false;
  }
}
