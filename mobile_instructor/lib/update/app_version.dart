/// A semantic version (`1.0.10`, `v2.1.0-beta.1`) that compares correctly:
/// numerically per part (so 1.0.10 > 1.0.9), missing parts count as 0
/// (1.2 == 1.2.0), and a pre-release is older than its release
/// (1.0.0-beta < 1.0.0). Build metadata (`+5`) is ignored.
class AppVersion implements Comparable<AppVersion> {
  final List<int> numbers;
  final String? preRelease;

  const AppVersion(this.numbers, [this.preRelease]);

  static final _pattern = RegExp(
    r'^[vV]?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// Parses `1.2.3`, `v1.2.3`, `1.2.3+4`, `1.2.3-rc.1`; null if not a version.
  static AppVersion? tryParse(String raw) {
    final m = _pattern.firstMatch(raw.trim());
    if (m == null) return null;
    final numbers = m.group(1)!.split('.').map(int.tryParse).toList();
    if (numbers.any((n) => n == null)) return null;
    return AppVersion(numbers.cast<int>(), m.group(2));
  }

  bool get isPreRelease => preRelease != null;

  @override
  int compareTo(AppVersion other) {
    final len = numbers.length > other.numbers.length
        ? numbers.length
        : other.numbers.length;
    for (var i = 0; i < len; i++) {
      final a = i < numbers.length ? numbers[i] : 0;
      final b = i < other.numbers.length ? other.numbers[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    // Same numbers: a release beats its pre-releases.
    final pa = preRelease, pb = other.preRelease;
    if (pa == null && pb == null) return 0;
    if (pa == null) return 1;
    if (pb == null) return -1;
    return _comparePre(pa, pb);
  }

  /// SemVer pre-release order: dot parts, numeric ones numerically.
  static int _comparePre(String a, String b) {
    final pa = a.split('.'), pb = b.split('.');
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      final na = int.tryParse(pa[i]), nb = int.tryParse(pb[i]);
      final c = (na != null && nb != null)
          ? na.compareTo(nb)
          : (na != null)
              ? -1
              : (nb != null)
                  ? 1
                  : pa[i].compareTo(pb[i]);
      if (c != 0) return c;
    }
    return pa.length.compareTo(pb.length);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(
      Object.hashAll(_trimmed), preRelease);

  List<int> get _trimmed {
    var end = numbers.length;
    while (end > 1 && numbers[end - 1] == 0) {
      end--;
    }
    return numbers.sublist(0, end);
  }

  @override
  String toString() =>
      numbers.join('.') + (preRelease == null ? '' : '-$preRelease');
}
