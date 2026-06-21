class SpacesBrowser {
  static void Function(String)? _handler;
  static void Function()? _onClose;

  static void open(String url, {void Function()? onClose}) {
    _onClose = onClose;
    _handler?.call(url);
  }

  static void fireOnClose() {
    final cb = _onClose;
    _onClose = null;
    cb?.call();
  }

  static void register(void Function(String) handler) => _handler = handler;

  static void unregister() {
    _handler = null;
    _onClose = null;
  }
}
