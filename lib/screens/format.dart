String _two(int n) => n.toString().padLeft(2, '0');

/// `HH:mm:ss` in local time.
String hms(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// `HH:mm` in local time.
String hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// `yyyy-MM-dd` in local time.
String ymd(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `Oct 22, 2026` in local time.
String mdy(DateTime t) => '${_months[t.month - 1]} ${t.day}, ${t.year}';
