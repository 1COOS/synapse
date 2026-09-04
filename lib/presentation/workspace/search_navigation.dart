import 'package:flutter/foundation.dart';

import '../../application/search/search_index.dart';

final class WorkspaceSearchNavigationRequest {
  const WorkspaceSearchNavigationRequest({
    required this.serial,
    required this.hit,
  });

  final int serial;
  final SearchHit hit;
}

final class WorkspaceSearchNavigationController extends ChangeNotifier {
  WorkspaceSearchNavigationRequest? _request;
  int _nextSerial = 1;

  WorkspaceSearchNavigationRequest? get request => _request;

  void reveal(SearchHit hit) {
    _request = WorkspaceSearchNavigationRequest(
      serial: _nextSerial++,
      hit: hit,
    );
    notifyListeners();
  }
}
