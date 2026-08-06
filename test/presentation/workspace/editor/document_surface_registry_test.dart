import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/document_surface_registry.dart';

void main() {
  test('flushes the currently attached pane surface', () async {
    final registry = DocumentSurfaceRegistry();
    final owner = Object();
    var flushes = 0;
    registry.attach(
      paneId: 'pane-1',
      owner: owner,
      flush: () async => ++flushes,
    );

    expect(await registry.flush('pane-1'), 1);
    expect(flushes, 1);
  });

  test('stale detach cannot remove a replacement surface', () async {
    final registry = DocumentSurfaceRegistry();
    final oldOwner = Object();
    final currentOwner = Object();
    registry.attach(paneId: 'pane-1', owner: oldOwner, flush: () async => 1);
    registry.attach(
      paneId: 'pane-1',
      owner: currentOwner,
      flush: () async => 2,
    );

    registry.detach(paneId: 'pane-1', owner: oldOwner);

    expect(await registry.flush('pane-1'), 2);
  });
}
