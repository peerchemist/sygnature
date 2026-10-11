import 'dart:isolate';
import 'dart:ui';

SendPort? lookup(String name) => IsolateNameServer.lookupPortByName(name);
bool register(SendPort port, String name) =>
    IsolateNameServer.registerPortWithName(port, name);
void remove(String name) => IsolateNameServer.removePortNameMapping(name);
// Only the owner's monitor removes the shared registration. Clients must never
// race a stale-port removal against registration of a replacement owner.
void remember(SendPort port, String name) {}
void forget(SendPort port, String name) {}
