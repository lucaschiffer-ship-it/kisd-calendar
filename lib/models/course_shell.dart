import 'package:flutter/material.dart';

enum Weekday {
  mon, tue, wed, thu, fri, sat, sun;

  String get label => switch (this) {
    Weekday.mon => 'Mon',
    Weekday.tue => 'Tue',
    Weekday.wed => 'Wed',
    Weekday.thu => 'Thu',
    Weekday.fri => 'Fri',
    Weekday.sat => 'Sat',
    Weekday.sun => 'Sun',
  };
}

class MeetingTime {
  final Weekday weekday;
  final TimeOfDay startTime;
  final TimeOfDay endTime;

  const MeetingTime({
    required this.weekday,
    required this.startTime,
    required this.endTime,
  });

  MeetingTime copyWith({Weekday? weekday, TimeOfDay? startTime, TimeOfDay? endTime}) =>
      MeetingTime(
        weekday: weekday ?? this.weekday,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
      );
}

class CourseLink {
  final String url;
  final String label;

  const CourseLink({required this.url, required this.label});
}

class CourseShell {
  final String id;
  final String title;
  final String description;
  final List<MeetingTime> meetingTimes;
  final DateTime startDate;
  final DateTime endDate;
  final String? location;
  final List<CourseLink> links;
  final bool isManual;

  const CourseShell({
    required this.id,
    required this.title,
    required this.description,
    required this.meetingTimes,
    required this.startDate,
    required this.endDate,
    this.location,
    required this.links,
    required this.isManual,
  });
}
