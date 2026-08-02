import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../../../application/exports/note_pdf_export.dart';
import 'workspace_theme.dart';

final class NotePdfExportDialog extends StatefulWidget {
  const NotePdfExportDialog({
    super.key,
    required this.snapshot,
    required this.exporter,
    required this.rasterizer,
    required this.fileSaver,
  });

  final NotePdfExportSnapshot snapshot;
  final NotePdfExporter exporter;
  final NotePdfPreviewRasterizer rasterizer;
  final NotePdfFileSaver fileSaver;

  @override
  State<NotePdfExportDialog> createState() => _NotePdfExportDialogState();
}

final class _NotePdfExportDialogState extends State<NotePdfExportDialog> {
  static const _previewCacheLimit = 6;

  NotePdfExportOptions _options = const NotePdfExportOptions();
  NotePdfBuildResult? _result;
  final LinkedHashMap<int, Future<NotePdfPreviewPage>> _previewFutures =
      LinkedHashMap<int, Future<NotePdfPreviewPage>>();
  var _buildGeneration = 0;
  var _building = true;
  var _saving = false;
  Object? _buildError;
  Object? _saveError;

  @override
  void initState() {
    super.initState();
    _startBuild();
  }

  void _startBuild() {
    final generation = ++_buildGeneration;
    final options = _options;
    unawaited(_build(generation, options));
  }

  Future<void> _build(int generation, NotePdfExportOptions options) async {
    try {
      final result = await widget.exporter.build(widget.snapshot, options);
      if (!mounted || generation != _buildGeneration) {
        return;
      }
      setState(() {
        _result = result;
        _building = false;
        _buildError = null;
        _previewFutures.clear();
      });
    } catch (error) {
      if (!mounted || generation != _buildGeneration) {
        return;
      }
      setState(() {
        _result = null;
        _building = false;
        _buildError = error;
        _previewFutures.clear();
      });
    }
  }

  void _setOptions(NotePdfExportOptions options) {
    if (options == _options) {
      return;
    }
    setState(() {
      _options = options;
      _result = null;
      _building = true;
      _buildError = null;
      _saveError = null;
      _previewFutures.clear();
    });
    _startBuild();
  }

  void _retryBuild() {
    setState(() {
      _result = null;
      _building = true;
      _buildError = null;
      _previewFutures.clear();
    });
    _startBuild();
  }

  Future<NotePdfPreviewPage> _previewPage(int pageIndex) {
    final cached = _previewFutures.remove(pageIndex);
    if (cached != null) {
      _previewFutures[pageIndex] = cached;
      return cached;
    }
    final result = _result;
    if (result == null) {
      return Future<NotePdfPreviewPage>.error(
        StateError('PDF preview is not ready.'),
      );
    }
    final future = widget.rasterizer.rasterPage(result.bytes, pageIndex);
    _previewFutures[pageIndex] = future;
    while (_previewFutures.length > _previewCacheLimit) {
      _previewFutures.remove(_previewFutures.keys.first);
    }
    return future;
  }

  Future<void> _save() async {
    final result = _result;
    if (result == null || _saving) {
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final outcome = await widget.fileSaver.save(
        result.bytes,
        suggestedName: widget.snapshot.title,
      );
      if (!mounted) {
        return;
      }
      if (outcome == NotePdfSaveOutcome.saved) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _saving = false);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _saveError = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final width = math.min(980.0, math.max(720.0, viewport.width - 48));
    final height = math.min(700.0, math.max(520.0, viewport.height - 48));
    return CupertinoPopupSurface(
      isSurfacePainted: true,
      child: SizedBox(
        key: const Key('note-pdf-export-dialog'),
        width: width,
        height: height,
        child: Column(
          children: [
            _buildTitlebar(),
            const SizedBox(
              height: 1,
              child: ColoredBox(color: workspaceLineColor),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 268, child: _buildSettings()),
                  const SizedBox(
                    width: 1,
                    child: ColoredBox(color: workspaceLineColor),
                  ),
                  Expanded(child: _buildPreview()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitlebar() {
    return SizedBox(
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '导出 PDF - ${widget.snapshot.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            CupertinoButton(
              key: const Key('note-pdf-cancel'),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: 6),
            CupertinoButton.filled(
              key: const Key('note-pdf-save'),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              onPressed: _result == null || _saving ? null : _save,
              child: _saving
                  ? const CupertinoActivityIndicator(
                      radius: 8,
                      color: CupertinoColors.white,
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettings() {
    final result = _result;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '纸张方向',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<NotePdfOrientation>(
            key: const Key('note-pdf-orientation'),
            groupValue: _options.orientation,
            children: const {
              NotePdfOrientation.portrait: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('纵向'),
              ),
              NotePdfOrientation.landscape: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('横向'),
              ),
            },
            onValueChanged: (value) {
              if (!_saving && value != null) {
                _setOptions(_options.copyWith(orientation: value));
              }
            },
          ),
          const SizedBox(height: 22),
          const Text(
            '页边距',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<NotePdfMarginPreset>(
            key: const Key('note-pdf-margin'),
            groupValue: _options.marginPreset,
            children: const {
              NotePdfMarginPreset.compact: Padding(
                padding: EdgeInsets.symmetric(horizontal: 5),
                child: Text('紧凑'),
              ),
              NotePdfMarginPreset.standard: Padding(
                padding: EdgeInsets.symmetric(horizontal: 5),
                child: Text('标准'),
              ),
              NotePdfMarginPreset.wide: Padding(
                padding: EdgeInsets.symmetric(horizontal: 5),
                child: Text('宽松'),
              ),
            },
            onValueChanged: (value) {
              if (!_saving && value != null) {
                _setOptions(_options.copyWith(marginPreset: value));
              }
            },
          ),
          const SizedBox(height: 22),
          Text(
            _building
                ? '正在生成真实分页预览…'
                : result == null
                ? '预览不可用'
                : 'A4 · ${result.pageCount} 页',
            key: const Key('note-pdf-page-count'),
            style: const TextStyle(color: workspaceMutedColor, fontSize: 13),
          ),
          if (_buildError != null) ...[
            const SizedBox(height: 12),
            _ErrorPanel(
              key: const Key('note-pdf-build-error'),
              message: '生成失败：${_errorText(_buildError!)}',
              actionLabel: '重试',
              onAction: _retryBuild,
            ),
          ],
          if (_saveError != null) ...[
            const SizedBox(height: 12),
            _ErrorPanel(
              key: const Key('note-pdf-save-error'),
              message: '写入失败：${_errorText(_saveError!)}',
            ),
          ],
          if (result != null && result.warnings.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text(
              '预览警告',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 7),
            Expanded(
              child: ListView.separated(
                key: const Key('note-pdf-warnings'),
                itemCount: result.warnings.length,
                separatorBuilder: (_, _) => const SizedBox(height: 7),
                itemBuilder: (context, index) => Text(
                  '• ${result.warnings[index].message}',
                  style: const TextStyle(
                    color: workspaceMutedColor,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final result = _result;
    if (_building) {
      return const Center(
        key: Key('note-pdf-building'),
        child: CupertinoActivityIndicator(radius: 14),
      );
    }
    if (result == null) {
      return const Center(child: Text('调整设置或重试以生成分页预览'));
    }
    return ColoredBox(
      color: workspaceSecondarySurfaceColor,
      child: ListView.builder(
        key: Key('note-pdf-preview-$_buildGeneration'),
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
        itemCount: result.pageCount,
        itemBuilder: (context, pageIndex) => _buildPreviewPage(pageIndex),
      ),
    );
  }

  Widget _buildPreviewPage(int pageIndex) {
    final aspectRatio = _options.orientation == NotePdfOrientation.portrait
        ? 1 / math.sqrt2
        : math.sqrt2;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: CupertinoColors.white,
              border: Border.all(color: workspaceLineColor),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 12,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: FutureBuilder<NotePdfPreviewPage>(
                key: Key('note-pdf-preview-page-$_buildGeneration-$pageIndex'),
                future: _previewPage(pageIndex),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text(
                        '本页预览失败',
                        style: TextStyle(color: workspaceDangerColor),
                      ),
                    );
                  }
                  final page = snapshot.data;
                  if (page == null) {
                    return const Center(child: CupertinoActivityIndicator());
                  }
                  return Image.memory(
                    page.pngBytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.systemRed.withValues(alpha: 0.08),
        border: Border.all(
          color: CupertinoColors.systemRed.withValues(alpha: 0.32),
        ),
        borderRadius: workspaceBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: const TextStyle(
                color: CupertinoColors.systemRed,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            if (actionLabel != null && onAction != null)
              CupertinoButton(
                key: const Key('note-pdf-retry'),
                padding: const EdgeInsets.only(top: 7),
                minimumSize: Size.zero,
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
          ],
        ),
      ),
    );
  }
}

String _errorText(Object error) {
  final text = error.toString();
  return text.replaceFirst(RegExp(r'^(Exception|StateError):\s*'), '');
}
