import 'package:flutter/cupertino.dart';

import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_theme.dart';

class WorkspacePane extends StatelessWidget {
  const WorkspacePane({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border(right: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: child,
    );
  }
}

class WorkspaceSplitDivider extends StatelessWidget {
  const WorkspaceSplitDivider({
    super.key,
    required this.axis,
    required this.onDragDelta,
  });

  final SplitAxis axis;
  final ValueChanged<double> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == SplitAxis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal
            ? (details) => onDragDelta(details.delta.dx)
            : null,
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => onDragDelta(details.delta.dy),
        child: SizedBox(
          width: horizontal ? workspaceNoteWorkspaceGutter : double.infinity,
          height: horizontal ? double.infinity : workspaceNoteWorkspaceGutter,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
