import 'package:flutter/material.dart';

class OneOffEvent {
  final String id;
  final DateTime date;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final String? title;
  final String? location;

  const OneOffEvent({
    required this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    this.title,
    this.location,
  });

  OneOffEvent copyWith({
    String? id,
    DateTime? date,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    String? title,
    String? location,
  }) =>
      OneOffEvent(
        id: id ?? this.id,
        date: date ?? this.date,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
        title: title ?? this.title,
        location: location ?? this.location,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'startTime': _fmtTime(startTime),
        'endTime': _fmtTime(endTime),
        'title': title,
        'location': location,
      };

  factory OneOffEvent.fromJson(Map<String, dynamic> j) => OneOffEvent(
        id: j['id'] as String,
        date: DateTime.parse(j['date'] as String),
        startTime: _parseTime(j['startTime'] as String),
        endTime: _parseTime(j['endTime'] as String),
        title: j['title'] as String?,
        location: j['location'] as String?,
      );

  static String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static TimeOfDay _parseTime(String s) {
    final parts = s.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  @override
  bool operator ==(Object other) => other is OneOffEvent && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
