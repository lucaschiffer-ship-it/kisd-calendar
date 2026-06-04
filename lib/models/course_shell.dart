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
  final String? lecturer;
  final List<CourseLink> links;
  final bool isManual;
  final bool isLiked;
  final bool isMyCourse;
  final bool isFavourite;

  const CourseShell({
    required this.id,
    required this.title,
    required this.description,
    required this.meetingTimes,
    required this.startDate,
    required this.endDate,
    this.location,
    this.lecturer,
    required this.links,
    required this.isManual,
    this.isLiked = false,
    this.isMyCourse = false,
    this.isFavourite = false,
  });

  CourseShell copyWith({
    String? id,
    String? title,
    String? description,
    List<MeetingTime>? meetingTimes,
    DateTime? startDate,
    DateTime? endDate,
    String? location,
    String? lecturer,
    List<CourseLink>? links,
    bool? isManual,
    bool? isLiked,
    bool? isMyCourse,
    bool? isFavourite,
  }) => CourseShell(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    meetingTimes: meetingTimes ?? this.meetingTimes,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    location: location ?? this.location,
    lecturer: lecturer ?? this.lecturer,
    links: links ?? this.links,
    isManual: isManual ?? this.isManual,
    isLiked: isLiked ?? this.isLiked,
    isMyCourse: isMyCourse ?? this.isMyCourse,
    isFavourite: isFavourite ?? this.isFavourite,
  );
}
