import 'dart:async';

import 'workspace_runtime.dart';

final class WorkspaceRuntimeCapture {
  const WorkspaceRuntimeCapture({
    required this.runtime,
    required this.generation,
  });

  final WorkspaceRuntime runtime;
  final int generation;
}

final class WorkspaceRuntimeManager {
  WorkspaceRuntime? _current;
  int _generation = 0;
  bool _isDisposed = false;

  int get generation {
    _ensureActive();
    return _generation;
  }

  WorkspaceRuntime? get current {
    _ensureActive();
    return _current;
  }

  WorkspaceRuntime requireCurrent() {
    return current ?? (throw StateError('No workspace runtime is installed.'));
  }

  WorkspaceRuntimeCapture? capture() {
    _ensureActive();
    final runtime = _current;
    return runtime == null
        ? null
        : WorkspaceRuntimeCapture(runtime: runtime, generation: _generation);
  }

  bool isCurrent(WorkspaceRuntimeCapture capture) {
    return !_isDisposed &&
        capture.generation == _generation &&
        identical(capture.runtime, _current);
  }

  void install(WorkspaceRuntime runtime) {
    _ensureActive();
    if (runtime.isDisposed) {
      throw StateError('Cannot install a disposed workspace runtime.');
    }
    if (identical(runtime, _current)) {
      return;
    }
    final previous = _current;
    _current = runtime;
    _generation += 1;
    previous?.dispose();
  }

  Future<void> installCandidate(
    FutureOr<WorkspaceRuntime> Function() create, {
    FutureOr<void> Function(WorkspaceRuntime runtime)? validate,
  }) async {
    _ensureActive();
    WorkspaceRuntime? candidate;
    try {
      candidate = await create();
      await validate?.call(candidate);
      install(candidate);
    } catch (_) {
      if (candidate != null && !identical(candidate, _current)) {
        candidate.dispose();
      }
      rethrow;
    }
  }

  void installCandidateSync(
    WorkspaceRuntime Function() create, {
    void Function(WorkspaceRuntime runtime)? validate,
  }) {
    _ensureActive();
    WorkspaceRuntime? candidate;
    try {
      candidate = create();
      validate?.call(candidate);
      install(candidate);
    } catch (_) {
      if (candidate != null && !identical(candidate, _current)) {
        candidate.dispose();
      }
      rethrow;
    }
  }

  void clear() {
    _ensureActive();
    final previous = _current;
    if (previous == null) {
      return;
    }
    _current = null;
    _generation += 1;
    previous.dispose();
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    final previous = _current;
    _current = null;
    _generation += 1;
    _isDisposed = true;
    previous?.dispose();
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('WorkspaceRuntimeManager has been disposed.');
    }
  }
}
