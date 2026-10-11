// Standalone Dart has no Flutter name server. It reuses an owner within the
// calling isolate; independent standalone processes are not concurrent clients.
import 'dart:isolate';

final _owners = <String, SendPort>{};
SendPort? lookup(String name) => _owners[name];
bool register(SendPort port, String name) {
  if (_owners.containsKey(name)) return false;
  _owners[name] = port;
  return true;
}

void remove(String name) => _owners.remove(name);
void remember(SendPort port, String name) => _owners[name] = port;
void forget(SendPort port, String name) {
  if (_owners[name] == port) _owners.remove(name);
}
