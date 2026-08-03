import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../models/app_event.dart';
import '../services/event_store.dart';
import '../services/spaces_browser.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';

const _kWeekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday',
  'Friday', 'Saturday', 'Sunday',
];
const _kMonths = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _fmtTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Unified sheet for app-store events: opens as a compact overview; the Edit
/// button expands the same card upward into edit mode. Changes are saved when
/// the sheet is dismissed (swipe, barrier tap or close button alike).
Future<void> showStoreEventSheet(
  BuildContext context,
  StoreOccurrence occ, {
  bool isNew = false,
}) async {
  final draft = _EventDraft(
    title: isNew ? '' : occ.event.title,
    location: occ.event.location ?? '',
    notes: occ.event.notes ?? '',
    start: occ.start,
    end: occ.end,
    collectionId: occ.event.collectionId,
  );
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (_) => _StoreEventSheet(occ: occ, draft: draft, isNew: isNew),
  );
  if (draft.deleted || !context.mounted) return;
  await _applyDraft(context, occ, draft);
}

// ─── Draft ────────────────────────────────────────────────────────────────────

/// Mutable holder the sheet writes into while it is open, so the result
/// survives every dismissal path and can be applied afterwards (including the
/// recurring-scope prompt, which needs a context that outlives the sheet).
class _EventDraft {
  _EventDraft({
    required this.title,
    required this.location,
    required this.notes,
    required this.start,
    required this.end,
    required this.collectionId,
  });

  String title;
  String location;
  String notes;
  DateTime start;
  DateTime end;
  String collectionId;
  bool deleted = false;
}

Future<void> _applyDraft(
    BuildContext context, StoreOccurrence occ, _EventDraft draft) async {
  final evt = occ.event;
  final title = draft.title.trim();
  final location = draft.location.trim();
  final notes = draft.notes.trim();

  // An emptied title never overwrites — a fresh event dismissed without a
  // name stays "New Event".
  final titleChanged = title.isNotEmpty && title != evt.title;
  final locationChanged = location != (evt.location ?? '');
  final notesChanged = notes != (evt.notes ?? '');
  final fieldsChanged = titleChanged || locationChanged || notesChanged;
  final timesChanged = draft.start != occ.start || draft.end != occ.end;
  final collectionChanged = draft.collectionId != evt.collectionId;

  // Nothing changed → no store call. updateEventFields flags userModified,
  // which would exclude scraped courses from future scrape reconciliation.
  if (!fieldsChanged && !timesChanged && !collectionChanged) return;

  if (collectionChanged) {
    EventStore.instance.setEventCollection(evt, draft.collectionId);
  }
  if (!fieldsChanged && !timesChanged) return;

  if (!evt.isRecurring) {
    EventStore.instance.updateEventFields(
      evt,
      title: titleChanged ? title : null,
      location: location.isEmpty ? null : location,
      notes: notes.isEmpty ? null : notes,
      start: timesChanged ? draft.start : null,
      end: timesChanged ? draft.end : null,
    );
    return;
  }

  // Recurring: field edits apply series-wide (overrides can only carry
  // times); time edits need a scope choice.
  if (fieldsChanged) {
    EventStore.instance.updateEventFields(
      evt,
      title: titleChanged ? title : null,
      location: location.isEmpty ? null : location,
      notes: notes.isEmpty ? null : notes,
    );
  }
  if (!timesChanged) return;

  final choice = await showCupertinoModalPopup<String>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: Text('“${titleChanged ? title : evt.title}” repeats weekly'),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx, 'this'),
          child: const Text('This event only'),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx, 'future'),
          child: const Text('All future events'),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.pop(ctx, 'cancel'),
        child: const Text('Cancel'),
      ),
    ),
  );
  switch (choice) {
    case 'this':
      EventStore.instance
          .overrideOccurrence(evt, occ.occurrenceDate, draft.start, draft.end);
    case 'future':
      EventStore.instance
          .splitSeries(evt, occ.occurrenceDate, draft.start, draft.end);
    default:
      // Time change dropped; field edits (if any) stand.
      break;
  }
}

// ─── Sheet ────────────────────────────────────────────────────────────────────

class _StoreEventSheet extends StatefulWidget {
  const _StoreEventSheet({
    required this.occ,
    required this.draft,
    required this.isNew,
  });

  final StoreOccurrence occ;
  final _EventDraft draft;
  final bool isNew;

  @override
  State<_StoreEventSheet> createState() => _StoreEventSheetState();
}

class _StoreEventSheetState extends State<_StoreEventSheet> {
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  late bool _editMode;

  _EventDraft get draft => widget.draft;

  @override
  void initState() {
    super.initState();
    _editMode = widget.isNew;
    _title = TextEditingController(text: draft.title);
    _location = TextEditingController(text: draft.location);
    _notes = TextEditingController(text: draft.notes);
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  static DateTime _roundTo15(DateTime d) => DateTime(d.year, d.month, d.day,
          d.hour)
      .add(Duration(minutes: ((d.minute + 7) ~/ 15) * 15));

  Future<void> _pickTime(bool start) async {
    var value = _roundTo15(start ? draft.start : draft.end);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Container(
        height: 260,
        color: AppColorScheme.current.surfaceElevated,
        child: SafeArea(
          top: false,
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.dateAndTime,
            use24hFormat: true,
            minuteInterval: 15,
            initialDateTime: value,
            onDateTimeChanged: (v) => value = v,
          ),
        ),
      ),
    );
    setState(() {
      if (start) {
        final duration = draft.end.difference(draft.start);
        draft.start = value;
        if (!draft.end.isAfter(draft.start)) {
          draft.end = draft.start.add(duration);
        }
      } else {
        draft.end = value.isAfter(draft.start)
            ? value
            : draft.start.add(const Duration(minutes: 15));
      }
    });
  }

  Future<void> _delete() async {
    final deleted = await _confirmDelete(context, widget.occ);
    if (!deleted || !mounted) return;
    draft.deleted = true;
    Navigator.of(context).pop();
  }

  EventCollection get _collection =>
      EventStore.instance.collectionById(draft.collectionId) ??
      widget.occ.collection;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: AppColorScheme.currentListenable,
      builder: (context, s, _) => AnimatedBuilder(
        animation: ThemeService.instance.glassEnabled,
        builder: (context, _) => _buildSheet(context, s),
      ),
    );
  }

  Widget _buildSheet(BuildContext context, AppColorScheme s) {
    final glass = ThemeService.instance.glassEnabled.value;
    const radius = BorderRadius.vertical(top: Radius.circular(AppRadius.sheet));

    final content = SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppThemeTokens.secondaryTextColor
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(AppRadius.handle),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_editMode) ..._buildEditMode(s) else ..._buildViewMode(s),
              ],
            ),
          ),
        ),
      ),
    );

    if (glass) {
      return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
              sigmaX: AppGlass.cardBlur, sigmaY: AppGlass.cardBlur),
          child: Container(
            decoration: BoxDecoration(
              color: s.glassHeaderTint,
              borderRadius: radius,
            ),
            child: content,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppThemeTokens.cardBackground,
        borderRadius: radius,
        border: Border.all(color: AppThemeTokens.cardBorder, width: 0.5),
      ),
      child: content,
    );
  }

  Widget _closeButton(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: AppThemeTokens.secondaryTextColor.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.close,
          size: 15,
          color: AppThemeTokens.secondaryTextColor,
        ),
      ),
    );
  }

  Widget _collectionChip(EventCollection col) {
    final color = col.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.tag),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Text(
        col.name.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.9,
          color: color,
        ),
      ),
    );
  }

  // ── View mode ───────────────────────────────────────────────────────────────

  List<Widget> _buildViewMode(AppColorScheme s) {
    final evt = widget.occ.event;
    // The attached calendar decides where the Spaces button leads — manual
    // events in a course calendar link to that course's space.
    final spacesUrl = _collection.spacesUrl ?? evt.spacesUrl;
    final title = draft.title.trim().isEmpty ? evt.title : draft.title.trim();
    final location = draft.location.trim();
    final notes = draft.notes.trim();
    final d = draft.start;
    final dateLabel =
        '${_kWeekdays[d.weekday - 1]}, ${_kMonths[d.month - 1]} ${d.day}';
    final timeLabel = '${_fmtTime(draft.start)} – ${_fmtTime(draft.end)}';

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              title,
              style:
                  AppTextStyles.contentHeading(color: AppThemeTokens.titleColor),
            ),
          ),
          const SizedBox(width: 12),
          _closeButton(context),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        '$dateLabel · $timeLabel'
        '${evt.isRecurring ? '  ·  weekly' : ''}',
        style: AppTextStyles.body(color: AppThemeTokens.secondaryTextColor),
      ),
      const SizedBox(height: 10),
      _collectionChip(_collection),
      if (location.isNotEmpty) ...[
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.location_on_outlined,
                size: 15, color: AppThemeTokens.locationColor),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                location,
                style: AppTextStyles.body(color: AppThemeTokens.locationColor),
              ),
            ),
          ],
        ),
      ],
      if (notes.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          notes,
          style: AppTextStyles.body(color: AppThemeTokens.secondaryTextColor),
        ),
      ],
      const SizedBox(height: 20),
      if (spacesUrl != null && spacesUrl.isNotEmpty) ...[
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              SpacesBrowser.open(spacesUrl);
            },
            child: const Text('Open in Spaces'),
          ),
        ),
        const SizedBox(height: 10),
      ],
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() => _editMode = true),
              child: const Text('Edit'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: s.danger,
                side: BorderSide(color: s.danger),
              ),
              onPressed: _delete,
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    ];
  }

  // ── Edit mode ───────────────────────────────────────────────────────────────

  List<Widget> _buildEditMode(AppColorScheme s) {
    final evt = widget.occ.event;
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              widget.isNew ? 'New event' : 'Edit event',
              style: AppTextStyles.navTitle(color: s.textPrimary),
            ),
          ),
          const SizedBox(width: 12),
          _closeButton(context),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _title,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onChanged: (v) => draft.title = v,
        style: AppTextStyles.bodyLarge(color: s.textPrimary),
        decoration: const InputDecoration(
          labelText: 'Title',
          hintText: 'New Event',
        ),
      ),
      const SizedBox(height: 16),
      _timeRow('Starts', draft.start, () => _pickTime(true), s),
      const SizedBox(height: 8),
      _timeRow('Ends', draft.end, () => _pickTime(false), s),
      if (evt.isRecurring) ...[
        const SizedBox(height: 6),
        Text(
          'Repeats weekly — time changes ask which events to move.',
          style: AppTextStyles.caption(color: s.textSecondary),
        ),
      ],
      const SizedBox(height: 16),
      Text('Calendar', style: AppTextStyles.body(color: s.textSecondary)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final col in EventStore.instance.collections)
            _calendarOption(col, s),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _location,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onChanged: (v) => draft.location = v,
        style: AppTextStyles.bodyLarge(color: s.textPrimary),
        decoration: const InputDecoration(labelText: 'Location'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _notes,
        minLines: 1,
        maxLines: 3,
        onChanged: (v) => draft.notes = v,
        style: AppTextStyles.bodyLarge(color: s.textPrimary),
        decoration: const InputDecoration(labelText: 'Notes'),
      ),
      const SizedBox(height: 20),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            setState(() => _editMode = false);
          },
          child: const Text('Done'),
        ),
      ),
    ];
  }

  Widget _calendarOption(EventCollection col, AppColorScheme s) {
    final selected = col.id == draft.collectionId;
    return GestureDetector(
      onTap: () => setState(() => draft.collectionId = col.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? col.color.withValues(alpha: 0.15)
              : AppThemeTokens.secondaryTextColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.tag),
          border: Border.all(
            color: selected ? col.color : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration:
                  BoxDecoration(color: col.color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                col.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body(
                  color: selected ? s.textPrimary : s.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeRow(
      String label, DateTime value, VoidCallback onTap, AppColorScheme s) {
    final d = value;
    final dateLabel =
        '${_kWeekdays[d.weekday - 1].substring(0, 3)}, ${_kMonths[d.month - 1].substring(0, 3)} ${d.day}';
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Text(label, style: AppTextStyles.body(color: s.textSecondary)),
          const Spacer(),
          Text(
            '$dateLabel · ${_fmtTime(d)}',
            style: AppTextStyles.bodyBold(color: s.accent),
          ),
        ],
      ),
    );
  }
}

// ─── Delete ───────────────────────────────────────────────────────────────────

/// Confirms and performs the delete. Returns true if the event (or this
/// occurrence) was deleted.
Future<bool> _confirmDelete(BuildContext context, StoreOccurrence occ) async {
  final evt = occ.event;
  if (evt.isRecurring) {
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Delete “${evt.title}”?'),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, 'this'),
            child: const Text('This event only'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: const Text('All events'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (choice == 'this') {
      EventStore.instance.cancelOccurrence(evt, occ.occurrenceDate);
      return true;
    }
    if (choice == 'all') {
      EventStore.instance.deleteEvent(evt);
      return true;
    }
    return false;
  }

  final confirmed = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text('Delete “${evt.title}”?'),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  EventStore.instance.deleteEvent(evt);
  return true;
}
