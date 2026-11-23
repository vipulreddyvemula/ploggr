import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';
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
    actions: [
      IconButton(
        tooltip: 'Refresh community',
        onPressed: () => ref.invalidate(fieldData),
        icon: const Icon(Icons.refresh),
      ),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final (label, route, icon) in [
              ('Cleanups', AppRoutes.cleanups, Icons.groups_outlined),
              ('Challenges', AppRoutes.challenges, Icons.flag_outlined),
              (
                'Leaderboard',
                AppRoutes.leaderboard,
                Icons.leaderboard_outlined,
              ),
            ])
              ActionChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                onPressed: () => openPage(context, route),
              ),
          ],
        ),
        const SectionTitle('Community posts'),
        PrimaryButton(
          'Share a post',
          icon: Icons.edit_outlined,
          onPressed: () => openPage(context, '/community/write'),
        ),
        const SizedBox(height: 12),
        FilterTabs(
          labels: const ['Everyone', 'My posts', 'Sightings'],
          selected: tab,
          onChanged: (i) => setState(() {
            tab = i;
            pages
              ..clear()
              ..add(null);
          }),
        ),
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
                          child: EcoCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor:
                                          context.colors.primaryContainer,
                                      foregroundColor:
                                          context.colors.onPrimaryContainer,
                                      child: Text(
                                        (post['author'] as String)
                                                .trim()
                                                .characters
                                                .firstOrNull
                                                ?.toUpperCase() ??
                                            'P',
                                      ),
                                    ),
                                    const SizedBox(width: AppSpace.md),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            post['author'],
                                            style: AppText.label,
                                          ),
                                          Text(
                                            localDate(
                                              context,
                                              post['createdAt'],
                                            ),
                                            style: AppText.caption,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: AppSpace.md),
                                Text(post['body']),
                                if (post['plogId'] != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: AppSpace.sm,
                                    ),
                                    child: EcoCard(
                                      color: context.colors.primaryContainer,
                                      padding: const EdgeInsets.all(
                                        AppSpace.md,
                                      ),
                                      onTap: post['mine'] == true
                                          ? () => openPage(
                                              context,
                                              '${AppRoutes.activity}/${post['plogId']}',
                                            )
                                          : null,
                                      child: Row(
                                        children: [
                                          const Icon(Icons.directions_walk),
                                          const SizedBox(width: AppSpace.sm),
                                          Expanded(
                                            child: Text(
                                              [
                                                'Shared cleanup',
                                                if (post['seconds']
                                                    case final int seconds)
                                                  formatWalkSummary(
                                                    seconds,
                                                    meters:
                                                        post['meters'] as num?,
                                                  ),
                                              ].join(' · '),
                                              style: AppText.label,
                                            ),
                                          ),
                                          if (post['mine'] == true)
                                            const Icon(Icons.chevron_right),
                                        ],
                                      ),
                                    ),
                                  ),
                                Wrap(
                                  spacing: 4,
                                  children: [
                                    FieldAction(
                                      post['liked'] == true
                                          ? 'Unlike · ${post['likes']}'
                                          : 'Like · ${post['likes']}',
                                      () => writeField(
                                        ref,
                                        'PUT',
                                        'community/posts/${post['id']}/reaction',
                                        data: {
                                          'selected': post['liked'] != true,
                                        },
                                        reload: [path],
                                      ),
                                      icon: post['liked'] == true
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                    ),
                                    TextButton.icon(
                                      onPressed: () => openPage(
                                        context,
                                        '/community/post/${post['id']}',
                                      ),
                                      icon: const Icon(
                                        Icons.chat_bubble_outline,
                                      ),
                                      label: Text(
                                        'Comment · ${post['comments']}',
                                      ),
                                    ),
                                    if (post['mine'] == true) ...[
                                      TextButton(
                                        onPressed: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                PostComposer(post: post),
                                          ),
                                        ),
                                        child: const Text('Edit'),
                                      ),
                                      FieldAction('Delete', () async {
                                        if (await confirmAction(
                                              context,
                                              'Delete this post?',
                                              'Delete',
                                            ) &&
                                            mounted) {
                                          await writeField(
                                            ref,
                                            'DELETE',
                                            'community/posts/${post['id']}',
                                            reload: [path],
                                          );
                                        }
                                      }),
                                    ] else
                                      FieldAction('Report post', () async {
                                        await writeField(
                                          ref,
                                          'PUT',
                                          'community/posts/${post['id']}/flag',
                                        );
                                        if (context.mounted) {
                                          toast(
                                            context,
                                            'Reported for moderator review.',
                                          );
                                        }
                                      }),
                                  ],
                                ),
                              ],
                            ),
                          ),
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
