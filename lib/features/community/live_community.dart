import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/services.dart';
import '../../shared/widgets/eco_art.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/bottom_navigation.dart';
import '../../shared/widgets/ploggr_ui.dart';
import 'field_data.dart';
import '../home/activity_overview.dart';
import '../spots/explore_page.dart' show OpenSightings;

class LiveCommunity extends ConsumerStatefulWidget {
  const LiveCommunity({super.key});
  @override
  ConsumerState<LiveCommunity> createState() => _CommunityState();
}

class _CommunityState extends ConsumerState<LiveCommunity> {
  int tab = 0;
  final pages = <String?>[null];
  @override
  Widget build(BuildContext context) => AppPage(
    title: 'Community',
    root: true,
    bottomNavigation: const BottomNavBar(),
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
    tabHeader: TabHeader(
      title: 'Community',
      subtitle: 'Connect, clean and create impact together.',
      action: IconButton(
        tooltip: 'Refresh community',
        onPressed: () => ref.invalidate(fieldData),
        icon: const Icon(Icons.refresh),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveTiles(
          minWidth: 88,
          children: [
            for (final (label, route, icon) in [
              ('Cleanups', AppRoutes.cleanups, Icons.groups_outlined),
              ('Challenges', AppRoutes.challenges, Icons.flag_outlined),
              (
                'Leaderboard',
                AppRoutes.leaderboard,
                Icons.emoji_events_outlined,
              ),
            ])
              EcoCard(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 2,
                ),
                onTap: () => openPage(context, route),
                child: Column(
                  children: [
                    Icon(icon, size: 25, color: context.colors.primary),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: AppText.label.copyWith(
                        fontSize: 13,
                        color: context.colors.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilterTabs(
          labels: const ['Feed', 'My Posts', 'Sightings'],
          selected: tab,
          onChanged: (i) => setState(() {
            tab = i;
            pages
              ..clear()
              ..add(null);
          }),
        ),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: () => openPage(context, '/community/write'),
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.primaryContainer,
            foregroundColor: context.colors.onPrimaryContainer,
          ),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Share a post'),
        ),
        const SizedBox(height: 4),
        if (tab == 2)
          const OpenSightings()
        else
          for (final cursor in pages)
            Builder(
              builder: (context) {
                final path =
                    'community/posts?mine=${tab == 1}${cursor == null ? '' : '&before=$cursor'}';
                return FieldData(
                  path,
                  (d) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if ((d['items'] as List).isEmpty && cursor == null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: AppNotice(
                            tab == 1
                                ? 'Your shared cleanups will appear here.'
                                : 'No posts yet. Share a cleanup with the community.',
                          ),
                        ),
                      for (final post in d['items'])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: _FeedPost(post: post, path: path),
                        ),
                      if (cursor == pages.last && d['next'] != null)
                        TextButton(
                          onPressed: () => setState(() => pages.add(d['next'])),
                          child: const Text('Load more posts'),
                        ),
                    ],
                  ),
                );
              },
            ),
      ],
    ),
  );
}

class _FeedPost extends ConsumerWidget {
  const _FeedPost({required this.post, required this.path});
  final Map post;
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = post['mine'] == true;
    final id = post['id'];
    final liked = post['liked'] == true;
    final linked = post['plogId'] != null;
    final author = post['author'] as String;
    Future<void> more(String action) async {
      try {
        if (action == 'Edit') {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PostComposer(post: post)),
          );
        } else if (action == 'Delete') {
          if (await confirmAction(context, 'Delete this post?', 'Delete') &&
              context.mounted) {
            await writeField(
              ref,
              'DELETE',
              'community/posts/$id',
              reload: [path],
            );
          }
        } else {
          await writeField(ref, 'PUT', 'community/posts/$id/flag');
          if (context.mounted) toast(context, 'Reported for moderator review.');
        }
      } catch (_) {
        if (context.mounted) {
          toast(context, 'Could not save. Check your connection and retry.');
        }
      }
    }

    return EcoCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: context.colors.primaryContainer,
                foregroundColor: context.colors.primary,
                child: Text(
                  author.trim().characters.firstOrNull?.toUpperCase() ?? 'P',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(author, style: AppText.label),
                    Text(
                      "${localDate(context, post['createdAt'])} · ${linked ? 'Plog session' : 'Community post'}",
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Post options',
                icon: const Icon(Icons.more_horiz),
                onSelected: more,
                itemBuilder: (_) => [
                  for (final action
                      in mine ? ['Edit', 'Delete'] : ['Report post'])
                    PopupMenuItem(value: action, child: Text(action)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(post['body'], style: AppText.body),
          if (linked)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: EcoCard(
                color: context.colors.primaryContainer,
                padding: const EdgeInsets.all(10),
                onTap: mine
                    ? () => openPage(
                        context,
                        '${AppRoutes.activity}/${post['plogId']}',
                      )
                    : null,
                child: Row(
                  children: [
                    Icon(Icons.directions_walk, color: context.colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          'Shared cleanup',
                          if (post['seconds'] case final int seconds)
                            formatWalkSummary(
                              seconds,
                              meters: post['meters'] as num?,
                            ),
                        ].join(' · '),
                        style: AppText.label,
                      ),
                    ),
                    if (mine) const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          const Divider(),
          Row(
            children: [
              Flexible(
                child: Tooltip(
                  message: liked ? 'Unlike' : 'Like',
                  child: FieldAction(
                    "${post['likes']}",
                    () => writeField(
                      ref,
                      'PUT',
                      'community/posts/$id/reaction',
                      data: {'selected': !liked},
                      reload: [path],
                    ),
                    icon: liked ? Icons.favorite : Icons.favorite_border,
                  ),
                ),
              ),
              Flexible(
                child: TextButton.icon(
                  onPressed: () => openPage(context, '/community/post/$id'),
                  icon: const Icon(
                    Icons.chat_bubble_outline,
                    semanticLabel: 'Comments',
                  ),
                  label: Text("${post['comments']}"),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Share post text',
                icon: const Icon(Icons.share_outlined),
                onPressed: () async {
                  try {
                    await const MethodChannel(
                      'ploggr/share',
                    ).invokeMethod<void>('text', post['body']);
                  } on MissingPluginException {
                    if (context.mounted) {
                      await showDialog<void>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: const Text('Share post text'),
                          content: SelectableText(post['body']),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    }
                  } on PlatformException {
                    if (context.mounted) {
                      toast(context, 'Could not open sharing.');
                    }
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PostComposer extends ConsumerStatefulWidget {
  const PostComposer({super.key, this.plog, this.post});
  final String? plog;
  final Map? post;
  @override
  ConsumerState<PostComposer> createState() => _PostState();
}

class _PostState extends ConsumerState<PostComposer> {
  late final body = TextEditingController(text: widget.post?['body'] ?? '');
  late final String id = widget.post?['id'] ?? const Uuid().v4();
  @override
  void dispose() {
    body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPage(
    title: widget.plog != null
        ? 'Share cleanup'
        : widget.post != null
        ? 'Edit post'
        : 'Share a post',
    bottomAction: FieldAction(
      'Publish',
      body.text.trim().isEmpty
          ? null
          : () async {
              await writeField(
                ref,
                'PUT',
                'community/posts/$id',
                data: {'body': body.text.trim(), 'plogId': ?widget.plog},
              );
              if (!context.mounted) return;
              ref.invalidate(fieldData);
              if (widget.post != null) {
                Navigator.pop(context);
              } else {
                switchPage(context, AppRoutes.community);
              }
            },
      primary: true,
    ),
    child: Column(
      children: [
        if (widget.plog != null)
          const ListTile(
            leading: Icon(Icons.eco_outlined),
            title: Text('Completed Plog'),
            subtitle: Text(
              'Shares active time and any recorded distance. Your route and pickup photos stay private.',
            ),
          ),
        TextField(
          controller: body,
          maxLength: 1000,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'What would you like to share?',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    ),
  );
}

class PostComments extends ConsumerStatefulWidget {
  const PostComments(this.id, {super.key});
  final String id;
  @override
  ConsumerState<PostComments> createState() => _CommentsState();
}

class _CommentsState extends ConsumerState<PostComments> {
  final body = TextEditingController();
  String id = const Uuid().v4();
  @override
  void dispose() {
    body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = 'community/posts/${widget.id}/comments';
    return AppPage(
      title: 'Comments',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: body,
            maxLength: 500,
            decoration: const InputDecoration(labelText: 'Write a comment'),
            onChanged: (_) => setState(() {}),
          ),
          FieldAction(
            'Post comment',
            body.text.trim().isEmpty
                ? null
                : () async {
                    await writeField(
                      ref,
                      'PUT',
                      '$path/$id',
                      data: {'body': body.text.trim()},
                    );
                    if (!mounted) return;
                    setState(() {
                      body.clear();
                      id = const Uuid().v4();
                    });
                    ref.invalidate(fieldData);
                  },
            primary: true,
          ),
          FieldData(
            path,
            (rows) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No comments yet.'),
                  ),
                for (final c in rows)
                  ListTile(
                    title: Text(c['body']),
                    subtitle: Text(
                      '${c['author']} · ${localDate(context, c['createdAt'])}',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
