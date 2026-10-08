import 'package:flutter/material.dart';

import '../../widgets/logout_action.dart';
import 'attendance_tab.dart';
import 'scan_tab.dart';

/// Instructor interface root: bottom navigation between scanning today's
/// events and browsing attendance for every event.
class InstructorHome extends StatefulWidget {
  const InstructorHome({super.key});

  @override
  State<InstructorHome> createState() => _InstructorHomeState();
}

class _InstructorHomeState extends State<InstructorHome> {
  int _index = 0;

  static const _titles = ['Instructor', 'Attendance'];

  /// Tabs are built on first visit (so the Attendance list isn't fetched
  /// until it is opened) and then kept alive by the [IndexedStack].
  final _visited = <int>{0};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: const [LogoutAction()],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          const ScanTab(),
          if (_visited.contains(1)) const AttendanceTab() else const SizedBox(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _index = i;
          _visited.add(i);
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner_outlined),
            selectedIcon: Icon(Icons.qr_code_scanner),
            label: 'Scan',
          ),
          NavigationDestination(
            icon: Icon(Icons.fact_check_outlined),
            selectedIcon: Icon(Icons.fact_check),
            label: 'Attendance',
          ),
        ],
      ),
    );
  }
}
