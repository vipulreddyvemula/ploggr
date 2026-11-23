import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../community/field_data.dart';
import '../spots/place_picker.dart';
import '../spots/spot_map.dart';

class LivePrograms extends ConsumerStatefulWidget {
  const LivePrograms({super.key, required this.events});
  final bool events;
  @override
  ConsumerState<LivePrograms> createState() => _ProgramsState();
}

class _ProgramsState extends ConsumerState<LivePrograms> {
  int tab = 0;
  String? selected;
  bool get events => widget.events;
  String get resource => events ? 'events' : 'challenges';
  Future<void> edit([Map? item]) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => _ProgramEditor(events: events, item: item),
    ),
  );
  @override
  Widget build(BuildContext context) => AppPage(
    title: events ? 'Community cleanups' : 'Challenges',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PrimaryButton(
          events ? 'Organize a cleanup' : 'Create a challenge',
          icon: Icons.add,
          onPressed: edit,
        ),
        const SizedBox(height: 12),
        FilterTabs(
          labels: events
              ? const ['Upcoming', 'Map', 'Joined']
              : const ['Active', 'Upcoming', 'Ended'],
          selected: tab,
          onChanged: (i) => setState(() => tab = i),
        ),
        FieldData(resource, (data) {
          final now = DateTime.now();
          final rows = (data as List).cast<Map>().where((r) {
            final start = DateTime.parse(r['startsAt']);
            if (events) {
              return start.isAfter(now) && (tab != 2 || r['joined'] == true);
            }
            final end = DateTime.parse(r['endsAt']);
            return tab == 1
                ? start.isAfter(now)
                : tab == 2
                ? end.isBefore(now)
                : !start.isAfter(now) && !end.isBefore(now);
          }).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (events && tab == 1 && rows.isNotEmpty)
                SpotMap(
                  points: {
                    for (final e in rows)
                      e['id']: (
                        latitude: (e['latitude'] as num).toDouble(),
                        longitude: (e['longitude'] as num).toDouble(),
                      ),
                  },
                  focus: (
                    latitude: (rows.first['latitude'] as num).toDouble(),
                    longitude: (rows.first['longitude'] as num).toDouble(),
                  ),
                  selected: selected,
                  onSelect: (id) => setState(() => selected = id),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: AppNotice(
                    events
                        ? (tab == 2
                              ? 'You haven’t joined an upcoming cleanup.'
                              : 'No upcoming cleanups yet.')
                        : 'No challenges in this period.',
                    actionLabel: tab == 0
                        ? null
                        : events
                        ? 'Browse upcoming cleanups'
                        : 'Show active challenges',
                    onAction: tab == 0 ? null : () => setState(() => tab = 0),
                  ),
                ),
              for (final row in [
                ...rows.where((r) => r['id'] == selected),
                ...rows.where((r) => r['id'] != selected),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: EcoCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row['title'], style: AppText.heading),
                        Text(
                          localDate(context, row['startsAt'], time: events) +
                              (events
                                  ? ''
                                  : ' – ${localDate(context, row['endsAt'])}'),
                          style: AppText.caption,
                        ),
                        if (events) ...[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.place_outlined),
                            title: Text(row['place']),
                            subtitle: Text(
                              row['joined'] == true
                                  ? 'You’re going'
                                  : 'Open to join',
                            ),
                          ),
                          Text(
                            'Hosted by ${row['organizer']} · ${row['going']} going',
                            style: AppText.caption,
                          ),
                          FieldAction(
                            row['joined'] == true
                                ? 'Leave cleanup'
                                : 'Join cleanup',
                            () => writeField(
                              ref,
                              'PUT',
                              'events/${row['id']}/rsvp',
                              data: {'selected': row['joined'] != true},
                              reload: [resource],
                            ),
                            primary: true,
                          ),
                        ] else ...[
                          const SizedBox(height: 8),
                          Text(
                            '${row['progress']} of ${row['goal']} completed Plogs',
                          ),
                          LinearProgressIndicator(
                            semanticsLabel: 'Challenge progress',
                            value:
                                ((row['progress'] as int) /
                                        (row['goal'] as int))
                                    .clamp(0, 1),
                          ),
                        ],
                        if (row['mine'] == true)
                          Wrap(
                            children: [
                              TextButton(
                                onPressed: () => edit(row),
                                child: const Text('Edit'),
                              ),
                              if (events)
                                FieldAction('Cancel cleanup', () async {
                                  if (await confirmAction(
                                        context,
                                        'Cancel this cleanup for everyone?',
                                        'Cancel cleanup',
                                      ) &&
                                      context.mounted) {
                                    await writeField(
                                      ref,
                                      'DELETE',
                                      'events/${row['id']}',
                                      reload: [resource],
                                    );
                                  }
                                }),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        }),
      ],
    ),
  );
}

class _ProgramEditor extends ConsumerStatefulWidget {
  const _ProgramEditor({required this.events, this.item});
  final bool events;
  final Map? item;
  @override
  ConsumerState<_ProgramEditor> createState() => _ProgramEditorState();
}

class _ProgramEditorState extends ConsumerState<_ProgramEditor> {
  late final title = TextEditingController(text: widget.item?['title'] ?? '');
  late final goal = TextEditingController(
    text: (widget.item?['goal'] ?? 5).toString(),
  );
  late final id = widget.item?['id'] ?? const Uuid().v4();
  late DateTime start =
      DateTime.tryParse(widget.item?['startsAt'] ?? '')?.toLocal() ??
      DateTime.now().add(const Duration(days: 1));
  late DateTime end =
      DateTime.tryParse(widget.item?['endsAt'] ?? '')?.toLocal() ??
      start.add(const Duration(days: 7));
  late ChosenPlace? place = widget.events && widget.item != null
      ? (
          name: widget.item!['place'] as String,
          point: (
            latitude: (widget.item!['latitude'] as num).toDouble(),
            longitude: (widget.item!['longitude'] as num).toDouble(),
          ),
        )
      : null;
  @override
  void dispose() {
    title.dispose();
    goal.dispose();
    super.dispose();
  }

  Future<void> date(bool last) async {
    final old = last ? end : start;
    final min = last
        ? DateUtils.dateOnly(start)
        : DateUtils.dateOnly(DateTime.now());
    final day = await showDatePicker(
      context: context,
      firstDate: min,
      lastDate: min.add(const Duration(days: 3650)),
      initialDate: old.isBefore(min) ? min : old,
    );
    if (day == null || !mounted) return;
    final t = widget.events
        ? await showTimePicker(
            context: context,
            initialTime: TimeOfDay.fromDateTime(old),
          )
        : (last
              ? const TimeOfDay(hour: 23, minute: 59)
              : const TimeOfDay(hour: 0, minute: 0));
    if (t != null && mounted) {
      setState(() {
        final d = DateTime(day.year, day.month, day.day, t.hour, t.minute);
        if (last) {
          end = d;
        } else {
          start = d;
          if (!end.isAfter(start)) end = start.add(const Duration(days: 1));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events, target = int.tryParse(goal.text) ?? 0;
    final valid =
        title.text.trim().length >= 2 &&
        (events
            ? place != null && start.isAfter(DateTime.now())
            : target >= 1 && target <= 1000 && end.isAfter(start));
    final resource = events ? 'events' : 'challenges';
    return AppPage(
      title: events ? 'Organize cleanup' : 'Challenge details',
      bottomAction: FieldAction(
        'Save',
        valid
            ? () async {
                await writeField(
                  ref,
                  'PUT',
                  '$resource/$id',
                  data: {
                    'title': title.text.trim(),
                    'startsAt': start.toUtc().toIso8601String(),
                    if (events) ...{
                      'place': place!.name,
                      'latitude': place!.point.latitude,
                      'longitude': place!.point.longitude,
                    } else ...{
                      'goal': target,
                      'endsAt': end.toUtc().toIso8601String(),
                    },
                  },
                  reload: [resource],
                );
                if (context.mounted) Navigator.pop(context);
              }
            : null,
        primary: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: title,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: events ? 'Cleanup name' : 'Challenge name',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (events)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(place?.name ?? 'Choose meeting point'),
              onTap: () async {
                final v = await choosePlace(
                  context,
                  initial: place,
                  title: 'Choose meeting point',
                );
                if (v != null && mounted) setState(() => place = v);
              },
            )
          else
            TextField(
              controller: goal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Number of completed Plogs',
                helperText: 'Choose between 1 and 1,000.',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ListTile(
            title: Text(events ? 'Date and time' : 'Starts'),
            subtitle: Text(localDate(context, start, time: events)),
            trailing: const Icon(Icons.calendar_month),
            onTap: () => date(false),
          ),
          if (!events)
            ListTile(
              title: const Text('Ends'),
              subtitle: Text(localDate(context, end)),
              trailing: const Icon(Icons.calendar_month),
              onTap: () => date(true),
            ),
        ],
      ),
    );
  }
}

class LiveBadges extends StatelessWidget {
  const LiveBadges({super.key});
  @override
  Widget build(BuildContext context) => AppPage(
    title: 'My badges',
    child: FieldData(
      'badges',
      (rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppNotice(
            '${(rows as List).where((badge) => badge['earned'] != null).length} of ${rows.length} badges earned',
          ),
          const SizedBox(height: AppSpace.md),
          if (rows.isEmpty)
            const AppNotice('Achievements will appear here when available.'),
          for (final b in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: EcoCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    b['earned'] == null
                        ? Icons.lock_outline
                        : Icons.workspace_premium,
                    color: context.colors.onPrimaryContainer,
                  ),
                  title: Text(b['name']),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b['rule']),
                      if (b['earned'] != null)
                        Text('Earned ${localDate(context, b['earned'])}')
                      else ...[
                        Text('${b['progress']} of ${b['goal']}'),
                        if ((b['goal'] as num) > 0)
                          LinearProgressIndicator(
                            value: ((b['progress'] as num) / (b['goal'] as num))
                                .clamp(0, 1),
                            semanticsLabel: 'Progress toward ${b['name']}',
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
