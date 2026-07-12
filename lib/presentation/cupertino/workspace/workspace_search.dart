import 'package:flutter/cupertino.dart';

import '../../../infrastructure/cache/memory_search_cache.dart';
import 'workspace_theme.dart';

class WorkspaceSearchField extends StatelessWidget {
  const WorkspaceSearchField({
    super.key,
    this.textFieldKey,
    this.submitButtonKey,
    required this.controller,
    required this.busy,
    required this.onSearch,
  });

  final Key? textFieldKey;
  final Key? submitButtonKey;
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      key: textFieldKey,
      controller: controller,
      placeholder: '全文 + 语义搜索',
      prefix: const Padding(
        padding: EdgeInsets.only(left: 10),
        child: Icon(
          CupertinoIcons.search,
          size: 16,
          color: workspaceMutedColor,
        ),
      ),
      suffix: CupertinoButton(
        key: submitButtonKey,
        minimumSize: const Size.square(30),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        onPressed: busy ? null : onSearch,
        child: const Icon(CupertinoIcons.arrow_right, size: 16),
      ),
      onSubmitted: (_) => onSearch(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border.all(color: workspaceLineColor),
        borderRadius: workspaceBorderRadius,
      ),
    );
  }
}

class WorkspaceSearchResultRow extends StatelessWidget {
  const WorkspaceSearchResultRow({
    super.key,
    required this.result,
    required this.onTap,
  });

  final SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CupertinoButton(
        minimumSize: const Size.fromHeight(44),
        padding: EdgeInsets.zero,
        borderRadius: workspaceBorderRadius,
        onPressed: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: workspaceSurfaceColor,
            border: Border.all(color: workspaceSoftLineColor),
            borderRadius: workspaceBorderRadius,
          ),
          child: Row(
            children: [
              const Icon(
                CupertinoIcons.search,
                size: 16,
                color: workspaceMutedColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(result.title, overflow: TextOverflow.ellipsis),
                    Text(
                      result.reasons.map((reason) => reason.name).join(' + '),
                      style: const TextStyle(
                        color: workspaceMutedColor,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
