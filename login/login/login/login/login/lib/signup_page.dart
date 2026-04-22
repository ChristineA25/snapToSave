// lib/signup_page.dart
// Updates:
// 1) Password validator shows missing bullet requirements (uppercase, lowercase, number, symbol, >= 8).
// 2) Live checklist with ✓/✗ for each requirement (including length).
// 3) Keep over-length (>254) error + counter highlighting.
// 4) Username helper & rules unchanged (still shows note that strength applies to username if selected).
// 5) NEW: Email length limit (<= 320) enforced in validator + helper text shown under email field.
// 6) NEW: Phone registration now uses server-validated E.164 when available.
// 7) NEW: Verbose debug logging for validation, payload, and HTTP request/response.
//
// >>> UPDATED (Feb 2026):
// - _submit(): build mode-aware bodyMap with identifierType + correct fields.
// - _serverSignup(): take Map<String,dynamic> bodyMap and post as-is.
// - Stop submission if phone validation fails (return re-enabled).
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
// Ensure Characters extension is available for .characters.length
import 'package:characters/characters.dart';
import 'api_guard.dart'; // requireOnline + OfflineException

import 'package:dropdown_search/dropdown_search.dart';

import 'package:countries_utils/countries_utils.dart';

enum IdentifierType { username, email, phone }

// --- API base (Railway) ---
const String kApiBase = 'https://nodejs-production-53a4.up.railway.app';
const String kApiSignupBase = 'https://nodejs-production-f031.up.railway.app'; // from screenshot
const String kApiKey = ''; // optional

String _toAlpha2(String input) {
  final t = input.trim();
  // Already alpha-2 letters?
  if (RegExp(r'^[A-Za-z]{2}$').hasMatch(t)) return t.toUpperCase();
  // Handle flag emoji (two Regional Indicator Symbols)
  final runes = t.runes.toList();
  if (runes.length == 2 &&
      runes.every((cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF)) {
    final a = String.fromCharCode(0x41 + (runes[0] - 0x1F1E6));
    final b = String.fromCharCode(0x41 + (runes[1] - 0x1F1E6));
    return '$a$b';
  }
  // Fallback: uppercase whatever we got
  return t.toUpperCase();
}

// --- Data model for phone regions ---
class PhoneRegion {
  final String iso2;
  final String name;
  /// canonical '+<digits>' (no spaces/hyphens)
  final String code;
  /// optional pretty string like '+ 1-264' (from DB)
  final String? displayCode;
  final int min;
  final int max;

  PhoneRegion({
    required this.iso2,
    required this.name,
    required this.code,
    this.displayCode,
    required this.min,
    required this.max,
  });

  factory PhoneRegion.fromJson(Map<String, dynamic> j) => PhoneRegion(
        // Normalize to A–Z alpha-2 (e.g., "🇬🇧" -> "GB")
        iso2: _toAlpha2((j['iso2'] ?? '').toString()),
        name: (j['name'] ?? '').toString(),
        code: (j['code'] ?? '').toString(),
        displayCode: (j['displayCode'] as String?),
        min: (j['min'] ?? 0) as int,
        max: (j['max'] ?? 0) as int,
      );
}

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  IdentifierType _idType = IdentifierType.username;

  final _identifierCtrl = TextEditingController();
  final _countryCodeCtrl = TextEditingController(text: '+44'); // sensible default
  final _passwordCtrl = TextEditingController();

  // Security questions and answers
  static const List<String> _questions = <String>[
    'What is the name of your first pet?',
    'What was the model of your first phone?',
    'In what city were you born?',
    'What is the surname of your favourite teacher?',
    'What was the name of your primary school?',
    'What is your favourite food?'
  ];

  String _genUserId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(10)).join();
    // Generates a 12-digit userID
  }

  // FIXED QUESTIONS — always the same for every user
  static const String kFixedQ1 = 'What is the name of your first pet?';
  static const String kFixedQ2 = 'In what city were you born?';
  static const String kFixedQ3 = 'What was the name of your primary school?';

  // No dropdown choices anymore — questions are pre‑assigned
  String _q1 = "Loading security question...";
  String _q2 = "Loading security question...";
  String _q3 = "Loading security question...";

  final _a1Ctrl = TextEditingController();
  final _a2Ctrl = TextEditingController();
  final _a3Ctrl = TextEditingController();

  bool _isSubmitting = false;

  // --- Phone regions state ---
  List<PhoneRegion> _regions = [];
  PhoneRegion? _selectedRegion;
  String? _regionsError;

  Future<String?> iso2ToIso3Lower(String iso2) async {
    final code = iso2.trim().toUpperCase();
    if (code.length != 2) return null;

    final uri = Uri.parse('https://restcountries.com/v3.1/alpha/$code');

    try {
      final res = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) {
        debugPrint('[ISO MAP] HTTP ${res.statusCode} for $code');
        return null;
      }

      final List<dynamic> data = jsonDecode(res.body);
      if (data.isEmpty) return null;

      final cca3 = data.first['cca3'];
      if (cca3 == null || cca3 is! String) return null;

      return cca3.toLowerCase();
    } catch (e) {
      debugPrint('[ISO MAP] Error converting $code → ISO3: $e');
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadRegions();
    _fetchAndSetRandomQuestion(); // 2. Call the new fetch function
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _countryCodeCtrl.dispose();
    _passwordCtrl.dispose();
    _a1Ctrl.dispose();
    _a2Ctrl.dispose();
    _a3Ctrl.dispose();
    super.dispose();
  }

  // --- Validation helpers ---
  final RegExp _upper = RegExp(r'[A-Z]');
  final RegExp _lower = RegExp(r'[a-z]');
  final RegExp _digit = RegExp(r'\d');
  final RegExp _symbol = RegExp(r'[^\w\s]');
  final RegExp _email =
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$'); // simplified
  final RegExp _digitsOnly = RegExp(r'^\d{1,20}$');
  final RegExp _usernamePattern = RegExp(r'^.{1,99}$');

  static const int kPasswordMaxLen = 254; // single source of truth
  static const int kEmailMaxLen = 320; // hard limit for email length

  /// Returns null if strong; otherwise a descriptive list of missing bits.
  String? _validateStrong(String value, String label) {
    final v = value; // do not trim to avoid hiding trailing-space intent
    final missing = <String>[];
    if (v.characters.length < 8) missing.add('≥ 8 characters');
    if (!_upper.hasMatch(v)) missing.add('an uppercase letter');
    if (!_lower.hasMatch(v)) missing.add('a lowercase letter');
    if (!_digit.hasMatch(v)) missing.add('a number');
    if (!_symbol.hasMatch(v)) missing.add('a symbol');
    if (missing.isEmpty) return null;
    // turn list into a readable sentence
    return '$label must include ${missing.join(', ')}.';
  }

  String? _validateIdentifier(String? value) {
    final raw = (value ?? '');
    final v = raw.trim(); // minor hardening
    switch (_idType) {
      case IdentifierType.username:
        if (v.isEmpty) return 'Username is required';
        final strongErr = _validateStrong(v, 'Username');
        if (strongErr != null) return strongErr;
        if (!_usernamePattern.hasMatch(v)) {
          return 'Username must be less than 100 characters.';
        }
        return null;
      case IdentifierType.email:
        if (v.isEmpty) return 'Email is required';
        // Length check — block > 320 characters (grapheme-aware)
        if (v.characters.length > kEmailMaxLen) {
          return 'Email must be $kEmailMaxLen characters or fewer';
        }
        if (!_email.hasMatch(v)) return 'Please enter a valid email address';
        return null;
      case IdentifierType.phone:
        if (v.isEmpty) {
          debugPrint('[VALIDATE][PHONE] fail: empty');
          return 'Phone number is required';
        }
        if (!_digitsOnly.hasMatch(v)) {
          debugPrint('[VALIDATE][PHONE] fail: non-digits -> "$v"');
          return 'Enter digits only';
        }
        final r = _selectedRegion;
        if (r == null) {
          debugPrint('[VALIDATE][PHONE] fail: no region selected');
          return 'Choose a country';
        }
        if (v.length < r.min ||
            v.length > r.max) {
          debugPrint(
              '[VALIDATE][PHONE] fail: length ${v.length} not in [${r.min}, ${r.max}] for ${r.iso2}');
          return 'Expected ${r.min}-${r.max} digits for ${r.name} (excluding country code).';
        }
        final cc = _countryCodeCtrl.text;
        if (cc.isEmpty ||
            !cc.startsWith('+')) {
          debugPrint('[VALIDATE][PHONE] fail: bad country code "$cc"');
          return 'Invalid country code';
        }
        debugPrint(
            '[VALIDATE][PHONE] pass: local="$v" iso2=${r.iso2} cc=$cc');
        return null;
    }
  }

  /// Password validator: shows over-length error, otherwise shows missing bullet rules.
  String? _validatePassword(String? value) {
    final v = (value ?? '');
    // Over-length error (field error + red counter)
    if (v.characters.length > kPasswordMaxLen) {
      return 'Password must be $kPasswordMaxLen characters or fewer.';
    }
    // Strength checks
    return _validateStrong(v, 'Password');
  }

  String? _validateQuestion(String? q) {
    if (q == null ||
        q.isEmpty) return 'Please choose a question';
    return null;
  }

  String? _validateAnswer(String? v) {
    final raw = (v ?? '');
    final ans = raw.trim(); // <<<
    if (ans.isEmpty) return 'Please provide an answer';
    if (ans.characters.length < 3) {
      return 'Use an answer that is at least 3 characters';
    }
    if (ans.characters.length > 255) {
      return 'Answer must be 255 characters or fewer';
    }
    if (_questions.contains(ans)) {
      return 'Avoid using the question text as your answer';
    }
    return null;
  }

  // NEW — add this helper
  void _onIdTypeChanged(IdentifierType v) {
    if (_idType == v) return;
    setState(() {
      // switch the mode
      _idType = v;
      // clear the identifier input every time we switch mode
      _identifierCtrl.clear();
      // when switching to PHONE, ensure country code is set to a default
      if (v == IdentifierType.phone) {
        final r = _selectedRegion;
        if (r != null) {
          _countryCodeCtrl.text = r.code; // canonical from selected region
        } else {
          _countryCodeCtrl.text = '+44'; // sensible fallback
        }
      }
    });
  }

  // ------------- Networking -------------
  String iso2ToFlagEmoji(String iso2) {
    if (iso2.length != 2) return '';
    const int base = 0x1F1E6; // 'A'
    final up = iso2.toUpperCase();
    final int a = base + (up.codeUnitAt(0) - 0x41);
    final int b = base + (up.codeUnitAt(1) - 0x41);
    return String.fromCharCodes([a, b]);
  }

  
  Future<void> _updateDisplayTimeAfterSignup({
    required String userId,
    required PhoneRegion region,
  }) async {
    final iso3Lower = await iso2ToIso3Lower(region.iso2);

    if (iso3Lower == null) {
      debugPrint('[DISPLAY_TIME] ISO2→ISO3 failed for ${region.iso2}');
      return;
    }

    final uri = Uri.parse('$kApiSignupBase/api/user/displayTime');

    final payload = {
      'userID': userId,
      'displayTime': iso3Lower, // ✅ identical to Settings
    };

    debugPrint('[DISPLAY_TIME] PUT $uri');
    debugPrint('[DISPLAY_TIME] payload: $payload');

    try {
      final res = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      debugPrint('[DISPLAY_TIME] HTTP ${res.statusCode}');
      debugPrint('[DISPLAY_TIME] BODY ${res.body}');
    } catch (e) {
      debugPrint('[DISPLAY_TIME] ERROR $e');
    }
  }

  Future<void> _loadRegions() async {
    try {
      final uri = Uri.parse('$kApiBase/phone/regions');
      final headers = <String, String>{'Accept': 'application/json'};
      if (kApiKey.isNotEmpty) headers['x-api-key'] = kApiKey;
      final res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final data = jsonDecode(res.body);
      final List list = data['regions'] ?? [];
      final regs = list.map((e) => PhoneRegion.fromJson(e)).toList().cast<PhoneRegion>();
      setState(() {
        _regions = regs;
        if (regs.isEmpty) {
          _selectedRegion = null;
        } else {
          final desiredCode = _countryCodeCtrl.text.replaceAll(' ', '');
          PhoneRegion selected;
          final byCode = regs.where((r) => r.code == desiredCode);
          if (byCode.isNotEmpty) {
            selected = byCode.first;
          } else {
            final gb = regs.where((r) => r.iso2.toUpperCase() == 'GB');
            selected = gb.isNotEmpty ? gb.first : regs.first;
          }
          _selectedRegion = selected;
          _countryCodeCtrl.text = selected.code; // canonical code
        }
        _regionsError = null;
      });
    } catch (_) {
      setState(() {
        _regionsError = 'Could not load countries. Using default +44.';
        if (_selectedRegion == null) {
          _selectedRegion = PhoneRegion(
            iso2: 'GB',
            name: 'United Kingdom',
            code: '+44',
            displayCode: '+44',
            min: 10,
            max: 10,
          );
          _countryCodeCtrl.text = _selectedRegion!.code;
        }
      });
    }
  }

  Future<void> _fetchAndSetRandomQuestion() async {
    try {
      final response = await http.get(
        Uri.parse('https://nodejs-production-f031.up.railway.app/api/admin/securityQuestions'),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> allQuestions = data['questions'];

        // 1. Generate a random index x between 0 and 29
        final random = Random();
        int x = random.nextInt(30); 

        setState(() {
          // 2. Select questions based on your offset logic
          // Question 1: Index x
          _q1 = allQuestions[x].toString();
          
          // Question 2: Index x + 30 (ensures it is from the 30-59 range)
          if (allQuestions.length > x + 30) {
            _q2 = allQuestions[x + 30].toString();
          }

          // Question 3: Index x + 60 (ensures it is from the 60-89 range)
          if (allQuestions.length > x + 60) {
            _q3 = allQuestions[x + 60].toString();
          }
        });
        
        debugPrint('[QUESTIONS] Base Index: $x. Loaded indices: $x, ${x+30}, ${x+60}');
      } else {
        throw Exception('Failed to load questions');
      }
    } catch (e) {
      debugPrint('[QUESTIONS] Error: $e');
      setState(() {
        _q1 = kFixedQ1; // Fallback to hardcoded if API fails
        // _q2 and _q3 are already initialized to kFixedQ2/Q3 in the class
      });
    }
  }

  Future<String?> _serverValidatePhone({required String iso2, required String local}) async {
    try {
      return await requireOnline<String?>(
        context: context,
        task: () async {
          final uri = Uri.parse('$kApiBase/phone/validate');
          final headers = <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          };
          if (kApiKey.isNotEmpty) headers['x-api-key'] = kApiKey;
          final body = jsonEncode({'iso2': iso2, 'local': local});
          final res = await http
              .post(uri, headers: headers, body: body)
              .timeout(const Duration(seconds: 10));
          final data = jsonDecode(res.body);
          if (res.statusCode == 200 && (data['valid'] == true)) {
            return (data['e164'] ?? '').toString();
          }
          return null;
        },
      );
    } on OfflineException {
      return null;
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final formOK = _formKey.currentState?.validate() ?? false;
    if (!formOK) {
      debugPrint('[SUBMIT] form validation failed on client');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please fix the highlighted fields.')),
        );
      }
      return;
    }

    try {
      await requireOnline<void>(
        context: context,
        task: () async {
          setState(() => _isSubmitting = true);

          String? e164ForPhone;
          final selected = _selectedRegion;
          final idValue = _identifierCtrl.text.trim();

          if (_idType == IdentifierType.phone && selected != null) {
            final sanitizedIso2 = _toAlpha2(selected.iso2);
            e164ForPhone = await _serverValidatePhone(
              iso2: sanitizedIso2,
              local: idValue,
            );
          }

          final newUserId = _genUserId();

          final bodyMap = <String, dynamic>{
            'userID': newUserId,
            'identifierType': _idType.name,
            'password': _passwordCtrl.text,
            'secuQuestion1': _q1,
            'secuAns1': _a1Ctrl.text,
            'secuQuestion2': _q2,
            'secuAns2': _a2Ctrl.text,
            'secuQuestion3': _q3,
            'secuAns3': _a3Ctrl.text,
          };

          if (_idType == IdentifierType.username) {
            bodyMap['username'] = idValue;
          } else if (_idType == IdentifierType.email) {
            bodyMap['email'] = idValue;
          } else if (_idType == IdentifierType.phone && selected != null) {
            bodyMap['phone_country_code'] = selected.code;
            bodyMap['phone_number'] = idValue;
            if (e164ForPhone != null) bodyMap['phoneE164'] = e164ForPhone;
          }

          final returnedUserId = await _serverSignup(bodyMap: bodyMap);

          if (returnedUserId != null) {
            // NEW: If signing up via phone, update the display time to ISO-3
            if (_idType == IdentifierType.phone && selected != null) {
              await _updateDisplayTimeAfterSignup(
                userId: returnedUserId,
                region: selected,
              );
            }

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Registration successful. ID: $returnedUserId')),
              );
              Navigator.pop(context, true);
            }
          }
          
          if (mounted) setState(() => _isSubmitting = false);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      debugPrint('[SUBMIT] exception: $e');
    }
  }

  // >>> UPDATED: accept a pre-built bodyMap and post as-is
  Future<String?> _serverSignup({
    required Map<String, dynamic> bodyMap,
  }) async {
    try {
      return await requireOnline<String?>(
        context: context,
        task: () async {
          final uri = Uri.parse('$kApiSignupBase/api/signup');
          final headers = <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          };
          if (kApiKey.isNotEmpty) headers['x-api-key'] = kApiKey;
          final body = jsonEncode(bodyMap);

          // Masked request log
          final masked = Map<String, dynamic>.from(bodyMap);
          if (masked.containsKey('password')) {
            final pw = masked['password'] as String;
            masked['password'] = '*' * pw.characters.length;
          }

          debugPrint('[HTTP][REQUEST] POST $uri');
          debugPrint('[HTTP][REQUEST] headers: $headers');
          debugPrint('[HTTP][REQUEST] body : $masked');

          final res = await http
              .post(uri, headers: headers, body: body)
              .timeout(const Duration(seconds: 10));

          debugPrint('[VALIDATE][HTTP] status=${res.statusCode} body=${res.body}');
          debugPrint('[HTTP][RESPONSE] status: ${res.statusCode}');
          debugPrint('[HTTP][RESPONSE] body : ${res.body}');

          if (res.statusCode == 201) {
            final data = jsonDecode(res.body);
            final returnedId = (data['userID'] ?? '').toString();
            final fallbackId = (bodyMap['userID'] ?? '').toString();
            return returnedId.isNotEmpty ? returnedId : fallbackId;
          }

          // --- NEW: friendly handling for duplicates (HTTP 409) ---
          if (res.statusCode == 409) {
            try {
              final data = jsonDecode(res.body);
              final serverMsg = (data['message'] ?? '').toString();
              final field = (data['field'] ?? '').toString();
              final friendly = serverMsg.isNotEmpty
                  ? serverMsg
                  : (field.isNotEmpty
                      ? '$field already in use. Please use another or use other provided options to sign up'
                      : 'Identifier like the security question answer(s) already in use. Please try a different one.');
                
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(friendly)),
                );
              }
            } catch (_) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Identifier already in use. Please try a different one.'),
                  ),
                );
              }
            }
            return null; // handled failure
          }

          // Other non-201 cases
          debugPrint('Signup failed: HTTP ${res.statusCode} ${res.body}');
          return null;
        },
      );
    } on OfflineException {
      return null;
    } catch (e) {
      debugPrint('Signup error: $e');
      return null;
    }
  }

  // ------------- UI -------------
  Widget _radioItem(String label, IdentifierType value) {
    return InkWell(
      onTap: () => _onIdTypeChanged(value), // NEW
      borderRadius: BorderRadius.circular(20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Radio<IdentifierType>(
            value: value,
            groupValue: _idType,
            onChanged: (v) => _onIdTypeChanged(v!), // NEW
          ),
          Text(label),
        ],
      ),
    );
  }

  // Identifier (username/email/phone)
  Widget _identifierField(ThemeData theme) {
    String label;
    String hint;
    IconData icon;
    TextInputType type;
    List<String>? hints;
    List<TextInputFormatter>? formatters;

    switch (_idType) {
      case IdentifierType.email:
        label = 'Email';
        hint = 'e.g. christine@example.com';
        icon = Icons.alternate_email;
        type = TextInputType.emailAddress;
        hints = const [AutofillHints.email];
        break;
      case IdentifierType.phone:
        label = 'Phone number';
        hint = 'e.g. 7123456789';
        icon = Icons.phone_outlined;
        type = TextInputType.phone;
        hints = const [AutofillHints.telephoneNumber];
        formatters = <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly];
        break;
      case IdentifierType.username:
      default:
        label = 'Username';
        hint = 'ie: chris';
        icon = Icons.person_outline;
        type = TextInputType.text;
        hints = const [AutofillHints.username];
    }

    final String? helperTextForField = _idType == IdentifierType.username
        ? 'Username must be less than 100 characters.'
        : (_idType == IdentifierType.phone && _selectedRegion != null
            ? 'Expected ${_selectedRegion!.min}-${_selectedRegion!.max} digits for ${_selectedRegion!.name} (excluding country code).'
            : (_idType == IdentifierType.email ? 'Email must be $kEmailMaxLen characters or fewer.' : null));

    return TextFormField(
      controller: _identifierCtrl,
      keyboardType: type,
      textInputAction: TextInputAction.next,
      autofillHints: hints,
      inputFormatters: formatters,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        helperText: helperTextForField,
        filled: true,
        fillColor: theme.colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        errorMaxLines: 5,
        helperMaxLines: 3,
      ),
      validator: _validateIdentifier,
      onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
    );
  }

  // Password field (with live counter)
  Widget _passwordField(ThemeData theme) {
    bool obscure = true;
    return StatefulBuilder(
      builder: (context, setSB) {
        return TextFormField(
          controller: _passwordCtrl,
          obscureText: obscure,
          enableSuggestions: false,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: 'Password',
            hintText: 'Enter your password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () => setSB(() => obscure = !obscure),
              icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
              tooltip: obscure ? 'Show password' : 'Hide password',
            ),
            helperText:
                'Must meet strength rules; recommended ≤ $kPasswordMaxLen characters.',
            filled: true,
            fillColor: theme.colorScheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            errorMaxLines: 6,
            helperMaxLines: 4,
          ),
          // Live counter that turns red when exceeding 254 chars
          buildCounter: (BuildContext context,
              {required int currentLength,
              required bool isFocused,
              required int? maxLength}) {
            final len = _passwordCtrl.text.characters.length;
            final over = len > kPasswordMaxLen;
            final style = Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: over
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                );
            return Padding(
              padding: const EdgeInsets.only(right: 12, top: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('$len/$kPasswordMaxLen', style: style),
              ),
            );
          },
          // No maxLength enforcement -> user can type; validator shows warnings/errors
          validator: _validatePassword,
          onFieldSubmitted: (_) => _submit(),
        );
      },
    );
  }

  // Live checklist (✓/✗) matching the on-screen bullet requirements
  Widget _passwordChecklist(ThemeData theme) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _passwordCtrl,
      builder: (_, value, __) {
        final text = value.text;
        final len = text.characters.length;
        final okUpper = _upper.hasMatch(text);
        final okLower = _lower.hasMatch(text);
        final okDigit = _digit.hasMatch(text);
        final okSymbol = _symbol.hasMatch(text);
        final okMin = len >= 8;

        Widget row(String label, bool ok) {
          final color = ok ? Colors.green : theme.colorScheme.error;
          final icon = ok ? Icons.check_circle : Icons.cancel;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Requirements:',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 6),
            row('At least one uppercase letter (A–Z)', okUpper),
            row('At least one lowercase letter (a–z)', okLower),
            row('At least one number (0–9)', okDigit),
            row('At least one symbol (e.g., ! @ # …)', okSymbol),
            row('At least 8 characters', okMin),
          ],
        );
      },
    );
  }

  Widget _fixedQuestionRow({
    required String question,
    required TextEditingController answerCtrl,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: answerCtrl,
          maxLength: 255,
          maxLengthEnforcement: MaxLengthEnforcement.none,
          decoration: InputDecoration(
            labelText: 'Your answer',
            helperText: 'Tip: Use a non‑obvious answer (max 255 chars).',
            filled: true,
            fillColor: theme.colorScheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            errorMaxLines: 3,
            helperMaxLines: 2,
          ),
          buildCounter: (_, {required currentLength, required isFocused, required maxLength}) =>
              const SizedBox.shrink(),
          validator: _validateAnswer,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.spa_outlined, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          'Snap To Save',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Back to Login'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHigh,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'Create your Save to Plant account. Choose how you want to register, fill in your details, and set up your security questions.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Register using:',
                      style:
                          theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 16,
                      runSpacing: 0,
                      children: [
                        _radioItem('Username', IdentifierType.username),
                        _radioItem('Email', IdentifierType.email),
                        _radioItem('Phone number', IdentifierType.phone),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // ----------------------- FORM -----------------------
                    Form(
                      key: _formKey,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      child: Column(
                        children: [
                          if (_idType == IdentifierType.phone)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                
                                DropdownSearch<PhoneRegion>(
                                  selectedItem: _selectedRegion,

                                  // ✅ items must be a List
                                  items: _regions,

                                  compareFn: (a, b) => a.iso2 == b.iso2,

                                  itemAsString: (r) {
                                    final flag = iso2ToFlagEmoji(r.iso2);
                                    final pretty = r.displayCode ?? r.code;
                                    return '${flag.isNotEmpty ? '$flag ' : ''}${r.name} ($pretty)';
                                  },

                                  // ✅ search/filter logic goes here
                                  asyncItems: (String filter) async {
                                    if (filter.isEmpty) return _regions;

                                    final f = filter.toLowerCase();
                                    return _regions.where((r) {
                                      return r.name.toLowerCase().contains(f) ||
                                            r.iso2.toLowerCase().contains(f) ||
                                            r.code.contains(f);
                                    }).toList();
                                  },

                                  popupProps: const PopupProps.menu(
                                    showSearchBox: true,
                                    searchFieldProps: TextFieldProps(
                                      decoration: InputDecoration(
                                        hintText: 'Search country or code…',
                                      ),
                                    ),
                                  ),

                                  // ✅ renamed correctly
                                  dropdownDecoratorProps: DropDownDecoratorProps(
                                    dropdownSearchDecoration: InputDecoration(
                                      labelText: 'Country',
                                      prefixIcon: const Icon(Icons.flag_outlined),
                                      helperText: _regionsError,
                                      filled: true,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),

                                  validator: (r) {
                                    if (_idType != IdentifierType.phone) return null;
                                    return r == null ? 'Choose a country' : null;
                                  },

                                  onChanged: (r) {
                                    setState(() {
                                      _selectedRegion = r;
                                      if (r != null) {
                                        _countryCodeCtrl.text = r.code;
                                        _identifierCtrl.clear();
                                        debugPrint('[REGIONS] Selected ISO2 ${r.iso2}');
                                      }
                                    });
                                  },
                                ),

                                const SizedBox(height: 8),
                                _identifierField(theme),
                              ],
                            )
                          else
                            _identifierField(theme),

                          const SizedBox(height: 12),
                          _passwordField(theme),
                          const SizedBox(height: 12),

                          // Live requirements checklist tied to the password input
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _passwordChecklist(theme),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _idType == IdentifierType.username
                                ? 'Note: The strength rules above apply to both the password and the username.'
                                : 'Note: The strength rules above apply to the password only. The username follows the length rule shown under its field.',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),

                          // >>> MOVED INSIDE THE FORM <<<
                          const SizedBox(height: 16),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Security questions',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _fixedQuestionRow(
                            question: _q1,
                            answerCtrl: _a1Ctrl,
                          ),
                          const SizedBox(height: 12),
                          _fixedQuestionRow(
                            question: _q2,
                            answerCtrl: _a2Ctrl,
                          ),
                          const SizedBox(height: 12),
                          _fixedQuestionRow(
                            question: _q3,
                            answerCtrl: _a3Ctrl,
                          ),
                          const SizedBox(height: 6),
                          // <<< END MOVED BLOCK
                        ],
                      ),
                    ),
                    // --------------------- END FORM ---------------------

                    // (spacing before buttons)
                    const SizedBox(height: 20),

                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isSubmitting ? null : _submit,
                            icon: const Icon(Icons.check_circle),
                            label: _isSubmitting
                                ? Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                      SizedBox(width: 8),
                                      Text('Submitting…'),
                                    ],
                                  )
                                : const Text('Submit'),
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.primaryContainer,
                              foregroundColor: theme.colorScheme.onPrimaryContainer,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isSubmitting ? null : () => Navigator.pop(context),
                            icon: const Icon(Icons.login),
                            label: const Text('Log in'),
                            style: OutlinedButton.styleFrom(
                              shape: const StadiumBorder(),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'After pressing Submit, you are agreeing to the fact that we are storing all your informtion to Railway, our cloud database. We will encrypt your email address or phone number. We will only collect information useful for suggesting financial advice to you. For more information about the cloud database, please access https://railway.com/\n\n\n',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        shape: const CircleBorder(),
        tooltip: 'Menu',
        child: const Icon(Icons.menu),
      ),
    );
  }
}

// Keeps a leading '+' while allowing only digits elsewhere.
class _EnsureLeadingPlusFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var raw = newValue.text.replaceAll(RegExp(r'[^\+\d]'), '');
    final hadPlus = raw.startsWith('+');
    if (!hadPlus) raw = '+$raw';
    final insertedPlus = !hadPlus;

    final base = newValue.selection.baseOffset;
    final extent = newValue.selection.extentOffset;
    final shift = insertedPlus ? 1 : 0;
    final newBase = (base + shift).clamp(1, raw.length);
    final newExtent = (extent + shift).clamp(1, raw.length);

    return TextEditingValue(
      text: raw,
      selection: TextSelection(baseOffset: newBase, extentOffset: newExtent),
      composing: TextRange.empty,
    );
  }
}

class _AnswerCounter extends StatelessWidget {
  const _AnswerCounter({
    required this.controller,
    required this.maxLength,
    this.textStyle,
    this.overflowStyle,
  });

  final TextEditingController controller;
  final int maxLength;
  final TextStyle? textStyle;
  final TextStyle? overflowStyle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (_, value, __) {
          final len = value.text.characters.length;
          final over = len > maxLength;
          final style = over ? (overflowStyle ?? textStyle) : textStyle;
          return Text('$len/$maxLength', style: style);
        });
  }
}