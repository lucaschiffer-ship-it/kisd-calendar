import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/course_shell.dart';
import '../widgets/course_shell_card.dart' show CourseShellCard;

class CourseShellEditScreen extends StatefulWidget {
  const CourseShellEditScreen({super.key, required this.shell});

  final CourseShell shell;

  @override
  State<CourseShellEditScreen> createState() => _CourseShellEditScreenState();
}

class _CourseShellEditScreenState extends State<CourseShellEditScreen> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _location;
  late List<MeetingTime> _meetingTimes;
  late List<TextEditingController> _linkLabels;
  late List<TextEditingController> _linkUrls;

  @override
  void initState() {
    super.initState();
    final s = widget.shell;
    _title = TextEditingController(text: s.title);
    _description = TextEditingController(text: s.description);
    _location = TextEditingController(text: s.location ?? '');
    _meetingTimes = List.from(s.meetingTimes);
    _linkLabels = s.links.map((l) => TextEditingController(text: l.label)).toList();
    _linkUrls = s.links.map((l) => TextEditingController(text: l.url)).toList();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _location.dispose();
    for (final c in _linkLabels) { c.dispose(); }
    for (final c in _linkUrls) { c.dispose(); }
    super.dispose();
  }

  void _save() {
    final loc = _location.text.trim();
    final links = List.generate(
      _linkLabels.length,
      (i) => CourseLink(label: _linkLabels[i].text.trim(), url: _linkUrls[i].text.trim()),
    );
    Navigator.pop(
      context,
      CourseShell(
        id: widget.shell.id,
        title: _title.text.trim(),
        description: _description.text.trim(),
        meetingTimes: List.from(_meetingTimes),
        startDate: widget.shell.startDate,
        endDate: widget.shell.endDate,
        location: loc.isEmpty ? null : loc,
        links: links,
        isManual: widget.shell.isManual,
      ),
    );
  }

  void _addMeetingTime() {
    setState(() {
      _meetingTimes.add(const MeetingTime(
        weekday: Weekday.mon,
        startTime: TimeOfDay(hour: 9, minute: 0),
        endTime: TimeOfDay(hour: 12, minute: 0),
      ));
    });
  }

  void _addLink() {
    setState(() {
      _linkLabels.add(TextEditingController());
      _linkUrls.add(TextEditingController());
    });
  }

  Future<void> _pickTime(int index, bool isStart) async {
    final mt = _meetingTimes[index];
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? mt.startTime : mt.endTime,
    );
    if (picked == null) return;
    setState(() {
      _meetingTimes[index] =
          isStart ? mt.copyWith(startTime: picked) : mt.copyWith(endTime: picked);
    });
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: Color(0xFF8E8E93),
          ),
        ),
      );

  Widget _field(TextEditingController ctrl, String label, {int maxLines = 1}) =>
      TextField(
        controller: ctrl,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        title: const Text(
          'Edit Shell',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              'Save',
              style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          _sectionLabel('DETAILS'),
          _field(_title, 'Title'),
          const SizedBox(height: 10),
          _field(_description, 'Description', maxLines: 3),
          const SizedBox(height: 10),
          _field(_location, 'Location (optional)'),

          _sectionLabel('MEETING TIMES'),
          ..._meetingTimes.asMap().entries.map((e) => _MeetingTimeCard(
                index: e.key,
                mt: e.value,
                onWeekdayChanged: (d) => setState(
                    () => _meetingTimes[e.key] = e.value.copyWith(weekday: d)),
                onPickStart: () => _pickTime(e.key, true),
                onPickEnd: () => _pickTime(e.key, false),
                onDelete: () => setState(() => _meetingTimes.removeAt(e.key)),
              )),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addMeetingTime,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add meeting time'),
          ),

          _sectionLabel('LINKS'),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex--;
                final lbl = _linkLabels.removeAt(oldIndex);
                final url = _linkUrls.removeAt(oldIndex);
                _linkLabels.insert(newIndex, lbl);
                _linkUrls.insert(newIndex, url);
              });
            },
            children: List.generate(
              _linkLabels.length,
              (i) => _LinkCard(
                key: ValueKey('link_$i'),
                index: i,
                labelCtrl: _linkLabels[i],
                urlCtrl: _linkUrls[i],
                onDelete: () => setState(() {
                  _linkLabels.removeAt(i).dispose();
                  _linkUrls.removeAt(i).dispose();
                }),
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addLink,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add link'),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _MeetingTimeCard extends StatelessWidget {
  const _MeetingTimeCard({
    required this.index,
    required this.mt,
    required this.onWeekdayChanged,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onDelete,
  });

  final int index;
  final MeetingTime mt;
  final void Function(Weekday) onWeekdayChanged;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<Weekday>(
                    initialValue: mt.weekday,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Day',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    items: Weekday.values
                        .map((d) => DropdownMenuItem(value: d, child: Text(d.label)))
                        .toList(),
                    onChanged: (d) { if (d != null) onWeekdayChanged(d); },
                  ),
                ),
                IconButton(
                  icon: Icon(CupertinoIcons.trash, size: 18, color: cs.error),
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onPickStart,
                    child: Text(CourseShellCard.fmtTime(mt.startTime)),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Text('–', style: TextStyle(fontSize: 16)),
                ),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onPickEnd,
                    child: Text(CourseShellCard.fmtTime(mt.endTime)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({
    super.key,
    required this.index,
    required this.labelCtrl,
    required this.urlCtrl,
    required this.onDelete,
  });

  final int index;
  final TextEditingController labelCtrl;
  final TextEditingController urlCtrl;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: labelCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                ReorderableDragStartListener(
                  index: index,
                  child: Icon(Icons.drag_handle, color: cs.onSurface.withAlpha(120)),
                ),
                IconButton(
                  icon: Icon(CupertinoIcons.trash, size: 18, color: cs.error),
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
