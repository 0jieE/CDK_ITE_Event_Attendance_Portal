import 'package:ite_attendance/models/event.dart';
import 'package:ite_attendance/services/token_storage.dart';

/// In-memory token store (the real one needs the platform keystore).
class FakeTokens extends TokenStorage {
  String? _access;
  String? _refresh;
  FakeTokens({String? access = 'access-1', String? refresh = 'refresh-1'})
      : _access = access,
        _refresh = refresh;

  @override
  Future<void> save({required String access, required String refresh}) async {
    _access = access;
    _refresh = refresh;
  }

  @override
  Future<void> saveAccess(String access) async => _access = access;

  @override
  Future<String?> get access async => _access;

  @override
  Future<String?> get refresh async => _refresh;

  @override
  Future<bool> get hasTokens async => _access != null;

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
  }
}

String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Event JSON as the API returns it.
Map<String, dynamic> eventJson(int id, String name, String start, String end) => {
      'id': id,
      'name': name,
      'semester_label': '1st Sem',
      'start_date': start,
      'end_date': end,
      'fine_rate': '50.00',
      'required_types': ['AM_IN', 'AM_OUT'],
      'is_active': true,
      'am_in_start': '07:00:00',
      'am_in_end': '08:00:00',
      'am_out_start': '11:30:00',
      'am_out_end': '12:00:00',
    };

/// Event model for pure-logic tests.
Event ev(int id, String start, String end) =>
    Event.fromJson(eventJson(id, 'Event $id', start, end));
