class SpacesBrowser {
  static void Function(String)? _handler;

  static void open(String url) => _handler?.call(url);

  static void register(void Function(String) handler) => _handler = handler;

  static void unregister() => _handler = null;
}
