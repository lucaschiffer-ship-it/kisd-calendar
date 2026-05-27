class KisdEvent {
  final String id;
  final String title;
  final String? organiser;
  final String? venue;
  final DateTime start;
  final DateTime end;
  final String? recurrenceRule;
  final String? url;

  const KisdEvent({
    required this.id,
    required this.title,
    this.organiser,
    this.venue,
    required this.start,
    required this.end,
    this.recurrenceRule,
    this.url,
  });

  bool get isRecurring => recurrenceRule != null && recurrenceRule!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'organiser': organiser,
        'venue': venue,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'recurrenceRule': recurrenceRule,
        'url': url,
      };

  factory KisdEvent.fromJson(Map<String, dynamic> j) => KisdEvent(
        id: j['id'] as String,
        title: j['title'] as String,
        organiser: j['organiser'] as String?,
        venue: j['venue'] as String?,
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
        recurrenceRule: j['recurrenceRule'] as String?,
        url: j['url'] as String?,
      );
}
