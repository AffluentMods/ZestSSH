/// Why the server would not take a ticket, a reply or a report for what was
/// attached to it, a screenshot or diagnostics (the server's limits on them,
/// the 3.4 security review): the words alone still go, so the person is
/// offered to send them without what was attached.
enum AttachmentRefusal {
  /// 413 `attachments_full`: this ticket holds all the screenshots and
  /// diagnostics it may. For good.
  full,

  /// 429 `attachments_hourly`: too many sent with something attached in the
  /// last hour.
  hourly,

  /// 429 `attachments_paused`: today's room for attachments sent without an
  /// account is used up, until midnight UTC.
  paused;

  /// The refusal the server's answer ([status], its JSON [body]) names; null
  /// for any other answer.
  static AttachmentRefusal? of(int status, Object? body) {
    final code = body is Map ? body['code'] : null;
    return switch ((status, code)) {
      (413, 'attachments_full') => full,
      (429, 'attachments_hourly') => hourly,
      (429, 'attachments_paused') => paused,
      _ => null,
    };
  }
}
