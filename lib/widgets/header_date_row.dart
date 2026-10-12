import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart' show AppColors, AppTextStyle;

const _kWeekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
const _kMonths = [
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];

/// The list page's header date and clock (`MON, OCT 12 … 15:20`), styled the
/// same, for the other pages' headers. Lay it out in a 52-tall box, like the
/// list's date row. Keeps its own clock so the minute tick only repaints this
/// row, not the page around it.
///
/// [titleColor] is passed in rather than read here so a theme change, which
/// rebuilds the page, re-renders the row with the new colour.
class HeaderDateRow extends StatefulWidget {
  const HeaderDateRow({super.key, required this.titleColor});

  final Color titleColor;

  @override
  State<HeaderDateRow> createState() => _HeaderDateRowState();
}

class _HeaderDateRowState extends State<HeaderDateRow> {
  DateTime _now = DateTime.now();
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      // Only HH:MM and the date are displayed — skip the rebuild until the
      // shown minute actually changes.
      if (now.minute == _now.minute &&
          now.hour == _now.hour &&
          now.day == _now.day) {
        return;
      }
      setState(() => _now = now);
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyle.cardTitle.copyWith(
      fontSize: 32,
      color: widget.titleColor,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          RichText(
            text: TextSpan(
              style: style,
              children: [
                TextSpan(
                  text: _kWeekdays[_now.weekday - 1],
                  style: const TextStyle(color: AppColors.accent),
                ),
                TextSpan(text: ', ${_kMonths[_now.month - 1]} ${_now.day}'),
              ],
            ),
          ),
          Text(
            '${_now.hour.toString().padLeft(2, '0')}:'
            '${_now.minute.toString().padLeft(2, '0')}',
            style: style,
          ),
        ],
      ),
    );
  }
}
