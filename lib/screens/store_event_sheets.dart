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

/// Detail sheet for app-store events (the interactive blocks on the timeline).
void showStoreEventDetail(BuildContext context, StoreOccurrence occ) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (_) => _StoreEventDetailSheet(occ: occ),
  );
}

// ─── Detail sheet ─────────────────────────────────────────────────────────────

class _StoreEventDetailSheet extends StatelessWidget {
  const _StoreEventDetailSheet({required this.occ});

  final StoreOccurrence occ;

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
    final evt = occ.event;
    final color = occ.collection.color;
    final d = occ.start;
    final dateLabel =
        '${_kWeekdays[d.weekday - 1]}, ${_kMonths[d.month - 1]} ${d.day}';
    final timeLabel = '${_fmtTime(occ.start)} – ${_fmtTime(occ.end)}';

    final content = SafeArea(
      top: false,
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
                  color:
                      AppThemeTokens.secondaryTextColor.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(AppRadius.handle),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    evt.title,
                    style: AppTextStyles.contentHeading(
                        color: AppThemeTokens.titleColor),
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppThemeTokens.secondaryTextColor
                          .withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close,
                      size: 15,
                      color: AppThemeTokens.secondaryTextColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$dateLabel · $timeLabel'
              '${evt.isRecurring ? '  ·  weekly' : ''}',
              style:
                  AppTextStyles.body(color: AppThemeTokens.secondaryTextColor),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.tag),
                border: Border.all(
                  color: color.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Text(
                occ.collection.name.toUpperCase(),
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.9,
                  color: color,
                ),
              ),
            ),
            if (evt.location != null && evt.location!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.location_on_outlined,
                      size: 15, color: AppThemeTokens.locationColor),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      evt.location!,
                      style: AppTextStyles.body(
                          color: AppThemeTokens.locationColor),
                    ),
                  ),
                ],
              ),
            ],
            if (evt.notes != null && evt.notes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                evt.notes!,
                style: AppTextStyles.body(
                    color: AppThemeTokens.secondaryTextColor),
              ),
            ],
            const SizedBox(height: 20),
            if (evt.spacesUrl != null && evt.spacesUrl!.isNotEmpty) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    SpacesBrowser.open(evt.spacesUrl!);
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
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showEditSheet(context, occ);
                    },
                    child: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColorScheme.current.danger,
                      side:
                          BorderSide(color: AppColorScheme.current.danger),
                    ),
                    onPressed: () => _confirmDelete(context, occ),
                    child: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
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
}

// ─── Delete ───────────────────────────────────────────────────────────────────

Future<void> _confirmDelete(BuildContext context, StoreOccurrence occ) async {
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
    } else if (choice == 'all') {
      EventStore.instance.deleteEvent(evt);
    } else {
      return;
    }
  } else {
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
    if (confirmed != true) return;
    EventStore.instance.deleteEvent(evt);
  }
  if (context.mounted) Navigator.of(context).pop();
}

// ─── Edit sheet ───────────────────────────────────────────────────────────────

void _showEditSheet(BuildContext context, StoreOccurrence occ) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (_) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _StoreEventEditSheet(occ: occ),
    ),
  );
}

class _StoreEventEditSheet extends StatefulWidget {
  const _StoreEventEditSheet({required this.occ});

  final StoreOccurrence occ;

  @override
  State<_StoreEventEditSheet> createState() => _StoreEventEditSheetState();
}

class _StoreEventEditSheetState extends State<_StoreEventEditSheet> {
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  late DateTime _start;
  late DateTime _end;

  @override
  void initState() {
    super.initState();
    final evt = widget.occ.event;
    _title = TextEditingController(text: evt.title);
    _location = TextEditingController(text: evt.location ?? '');
    _notes = TextEditingController(text: evt.notes ?? '');
    _start = evt.start;
    _end = evt.end;
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickTime(bool start) async {
    var value = start ? _start : _end;
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
            minuteInterval: 5,
            initialDateTime: value,
            onDateTimeChanged: (v) => value = v,
          ),
        ),
      ),
    );
    setState(() {
      if (start) {
        final duration = _end.difference(_start);
        _start = value;
        if (!_end.isAfter(_start)) _end = _start.add(duration);
      } else {
        _end = value.isAfter(_start)
            ? value
            : _start.add(const Duration(minutes: 15));
      }
    });
  }

  void _save() {
    final evt = widget.occ.event;
    final title = _title.text.trim();
    final loc = _location.text.trim();
    final notes = _notes.text.trim();
    EventStore.instance.updateEventFields(
      evt,
      title: title.isEmpty ? null : title,
      location: loc.isEmpty ? null : loc,
      notes: notes.isEmpty ? null : notes,
      // Times only for single events — recurring times are edited by dragging
      // (with the this-only / all-future choice).
      start: evt.isRecurring ? null : _start,
      end: evt.isRecurring ? null : _end,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    const radius = BorderRadius.vertical(top: Radius.circular(AppRadius.sheet));
    final evt = widget.occ.event;

    return Container(
      decoration: BoxDecoration(
        color: s.surfaceElevated,
        borderRadius: radius,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Edit event',
                  style: AppTextStyles.navTitle(color: s.textPrimary)),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                style: AppTextStyles.bodyLarge(color: s.textPrimary),
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _location,
                style: AppTextStyles.bodyLarge(color: s.textPrimary),
                decoration: const InputDecoration(labelText: 'Location'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                style: AppTextStyles.bodyLarge(color: s.textPrimary),
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              if (!evt.isRecurring) ...[
                const SizedBox(height: 16),
                _timeRow('Starts', _start, () => _pickTime(true), s),
                const SizedBox(height: 8),
                _timeRow('Ends', _end, () => _pickTime(false), s),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
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
