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
  WorkspaceRuntimeManager({
    WorkspaceRuntimeCleanupErrorReporter? cleanupErrorReporter,
  }) : _cleanupErrorReporter = cleanupErrorReporter;

  final WorkspaceRuntimeCleanupErrorReporter? _cleanupErrorReporter;
  WorkspaceRuntime? _current;
  int _generation = 0;
  int _candidateIntent = 0;
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
    _candidateIntent += 1;
    _install(runtime);
  }

  void _install(WorkspaceRuntime runtime) {
    if (runtime.isDisposed) {
      throw StateError('Cannot install a disposed workspace runtime.');
    }
    if (identical(runtime, _current)) {
      return;
    }
    final previous = _current;
    _current = runtime;
    _generation += 1;
    _disposeRuntime(previous);
  }

  Future<void> installCandidate(
    FutureOr<WorkspaceRuntime> Function() create, {
    FutureOr<void> Function(WorkspaceRuntime runtime)? validate,
  }) async {
    _ensureActive();
    final intent = ++_candidateIntent;
    WorkspaceRuntime? candidate;
    try {
      candidate = await create();
      await validate?.call(candidate);
      _ensureActive();
      if (intent != _candidateIntent) {
        _discardCandidate(candidate);
        candidate = null;
        return;
      }
      _install(candidate);
      candidate = null;
    } catch (_) {
      _discardCandidate(candidate);
      rethrow;
    }
  }

  void installCandidateSync(
    WorkspaceRuntime Function() create, {
    void Function(WorkspaceRuntime runtime)? validate,
  }) {
    _ensureActive();
    final intent = ++_candidateIntent;
    WorkspaceRuntime? candidate;
    try {
      candidate = create();
      validate?.call(candidate);
      if (intent != _candidateIntent) {
        _discardCandidate(candidate);
        candidate = null;
        return;
      }
      _install(candidate);
      candidate = null;
    } catch (_) {
      _discardCandidate(candidate);
      rethrow;
    }
  }

  void clear() {
    _ensureActive();
    _candidateIntent += 1;
    final previous = _current;
    if (previous == null) {
      return;
    }
    _current = null;
    _generation += 1;
    _disposeRuntime(previous);
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    final previous = _current;
    _current = null;
    _generation += 1;
    _candidateIntent += 1;
    _isDisposed = true;
    _disposeRuntime(previous);
  }

  void _disposeRuntime(WorkspaceRuntime? runtime) {
    runtime?.dispose(reportCleanupError: _cleanupErrorReporter);
  }

  void _discardCandidate(WorkspaceRuntime? candidate) {
    if (candidate != null && !identical(candidate, _current)) {
      _disposeRuntime(candidate);
    }
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('WorkspaceRuntimeManager has been disposed.');
    }
  }
}
