class KisdEvent {
  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String? venue;
  final String? organiser;
  final List<String> categories;
  final String recurrence;
  final bool isRecurring;
  final String? url;

  KisdEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.venue,
    this.organiser,
    required this.categories,
    required this.recurrence,
    required this.isRecurring,
    this.url,
  });

  factory KisdEvent.fromJson(Map<String, dynamic> json) => KisdEvent(
        id: json['id'] as String,
        title: json['title'] as String,
        start: DateTime.parse(json['start'] as String),
        end: DateTime.parse(json['end'] as String),
        venue: json['venue'] as String?,
        organiser: json['organiser'] as String?,
        categories: (json['categories'] as List<dynamic>).cast<String>(),
        recurrence: json['recurrence'] as String,
        isRecurring: json['isRecurring'] as bool,
        url: json['url'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'venue': venue,
        'organiser': organiser,
        'categories': categories,
        'recurrence': recurrence,
        'isRecurring': isRecurring,
        'url': url,
      };
}
