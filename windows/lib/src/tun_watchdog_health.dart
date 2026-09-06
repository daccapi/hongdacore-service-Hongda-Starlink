/// A failed HTTPS check remains pending until HTTPS itself succeeds. A valid
/// route table alone must never clear an internet reachability failure.
class TunWatchdogHealth {
  int _cycles = 0;
  bool _httpsRetry = false;

  bool nextRouteHealthyCycleNeedsHttps() => ++_cycles >= 10 || _httpsRetry;

  void recordHttps({required bool succeeded}) {
    _cycles = 0;
    _httpsRetry = !succeeded;
  }

  void reset() {
    _cycles = 0;
    _httpsRetry = false;
  }
}
