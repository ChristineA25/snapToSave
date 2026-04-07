// ============================================================================
// FORGOT LOGIN PAGE — UPDATED WITH DYNAMIC DATABASE QUESTIONS + HUMAN HOLD TEST
// ============================================================================

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'signup_page.dart';

import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
// Ensure Characters extension is available for .characters.length
import 'package:characters/characters.dart';
import 'api_guard.dart'; // requireOnline + OfflineException

import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'api_guard.dart'; // Ensure this matches your project structure

import 'package:dropdown_search/dropdown_search.dart';

import 'package:flutter/services.dart';

class ForgotLoginPage extends StatefulWidget {
  const ForgotLoginPage({super.key});

  @override
  State<ForgotLoginPage> createState() => _ForgotLoginPageState();
}

class _ForgotLoginPageState extends State<ForgotLoginPage> {

  bool _isProcessingTest = false; // New flag to prevent spamming/immediate reset

  IdentifierType _idType = IdentifierType.username;
  PhoneRegion? _selectedRegion;
  List<PhoneRegion> _regions = [];

  final _formKey = GlobalKey<FormState>();

  // =============================================================
  // DYNAMIC QUESTION STATE (Replaces fixed q1-q4 controllers)
  // =============================================================
  List<TextEditingController> _controllers = [];
  List<bool> _skipFlags = [];
  List<Map<String, String>> _dynamicQuestions = [];
  bool _isLoading = false;

  List<String> _primaryQuestions = []; // The first 30 questions
  List<String> _allQuestions = [];     // The full list of 100+ questions
  String? _selectedFirstQuestion;      // What the user picks

  // =============================================================
  // HUMAN PRESS-AND-HOLD TEST
  // =============================================================
  int _requiredSeconds = 0;
  int _currentSeconds = 0;
  Timer? _timer;
  bool _readyToRelease = false; 
  bool _holding = false;    
  bool _isHumanVerified = false; // Add this to your state variables    

  final Stopwatch _holdWatch = Stopwatch();
  static const int _graceSeconds = 1; 

  final humanTestKey = GlobalKey(); 

  // Constants and RegEx from signup_page.dart
  final RegExp _upper = RegExp(r'[A-Z]');
  final RegExp _lower = RegExp(r'[a-z]');
  final RegExp _digit = RegExp(r'\d');
  final RegExp _symbol = RegExp(r'[^\w\s]');
  final RegExp _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
  final RegExp _digitsOnly = RegExp(r'^\d{1,20}$');
  final RegExp _usernamePattern = RegExp(r'^.{1,99}$');

  static const int kPasswordMaxLen = 254;
  static const int kEmailMaxLen = 320;

  final TextEditingController _countryCodeCtrl = TextEditingController(text: '+44');
  final TextEditingController _identifierCtrl = TextEditingController(); // Your phone/email/user field

  @override
  void initState() {
    super.initState();
    _generateRequiredSeconds();
    _syncSecurityQuestions();
    _loadRegions(); // Load country codes on start
  }

  void _generateRequiredSeconds() {
    final rnd = Random();
    setState(() {
      _requiredSeconds = rnd.nextInt(4) + 2; // Requires 2-5 seconds
    });
  }

  @override
  void dispose() {
    // Correctly dispose of dynamic list of controllers
    for (var controller in _controllers) {
      controller.dispose();
    }
    _timer?.cancel();
    _holdWatch.stop();
    super.dispose();
  }

  Widget _connectionHint() {
  return StreamBuilder<InternetConnectionStatus>(
    stream: InternetConnectionChecker().onStatusChange,
    initialData: InternetConnectionStatus.connected,
    builder: (context, snap) {
      final offline = snap.data == InternetConnectionStatus.disconnected;
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: offline ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              offline ? Icons.wifi_off : Icons.wifi,
              size: 18,
              color: offline ? Colors.red : Colors.green,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                offline
                    ? 'You’re offline. Connect to the internet to recover your account.'
                    : 'Connected to the internet.',
                style: TextStyle(
                  fontSize: 12,
                  color: offline ? Colors.red.shade700 : Colors.green.shade700,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

  // =============================================================
  // DATA EXTRACTION (PAGINATION)
  // =============================================================
  Future<void> _syncAllDatabaseQuestions() async {
    setState(() => _isLoading = true);
    
    List<Map<String, String>> collectedQuestions = [];
    Set<String> uniqueQuestions = {}; 
    int currentPage = 1;
    const int pageSize = 200; 
    bool hasMore = true;

    try {
      while (hasMore) {
        final url = Uri.parse(
          'https://nodejs-production-f031.up.railway.app/api/admin/loginTable?page=$currentPage&pageSize=$pageSize'
        );
        
        final response = await http.get(url); 

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          List<dynamic> rows = data['rows'] ?? [];
          int total = data['total'] ?? 0;

          for (var row in rows) {
            for (int i = 1; i <= 3; i++) {
              String? qText = row['secuQuestion$i'];
              if (qText != null && qText.trim().isNotEmpty && !uniqueQuestions.contains(qText)) {
                uniqueQuestions.add(qText);
                collectedQuestions.add({
                  'question': qText,
                  'id': 'q_${collectedQuestions.length}'
                });
              }
            }
          }

          // Check if more pages exist based on total count
          if ((currentPage * pageSize) >= total || rows.isEmpty) {
            hasMore = false;
          } else {
            currentPage++;
          }
        } else {
          throw Exception('Failed to load login table');
        }
      }

      setState(() {
        _dynamicQuestions = collectedQuestions;
        // Correctly initialize state variables to fix "Undefined name" errors
        _controllers = List.generate(collectedQuestions.length, (_) => TextEditingController());
        _skipFlags = List.generate(collectedQuestions.length, (_) => false);
      });
      
    } catch (e) {
      _showFeedback("Error fetching all questions: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _syncSecurityQuestions() async {
  try {
    await requireOnline<void>(
      context: context,
      task: () async {
        setState(() => _isLoading = true);
        final response = await http.get(
          Uri.parse('https://nodejs-production-f031.up.railway.app/api/admin/securityQuestions'),
        );

        if (response.statusCode == 200) {
          final Map<String, dynamic> data = jsonDecode(response.body);
          final List<dynamic> questions = data['questions'] ?? [];
          setState(() {
            _allQuestions = questions.map((e) => e.toString()).toList();
            _primaryQuestions = _allQuestions.take(30).toList();
          });
        }
        setState(() => _isLoading = false);
      },
    );
  } on OfflineException {
    // API Guard handles the dialog; we just stop loading
    setState(() => _isLoading = false);
  } catch (e) {
    setState(() => _isLoading = false);
    _showFeedback("Error loading questions: $e");
  }
}

  void _onFirstQuestionSelected(String? selected) async {
    if (selected == null) return;

    // Find the index 'x' of the selected question
    int x = _allQuestions.indexOf(selected);

    if (x != -1 && x < 30) {
      setState(() => _isLoading = true);

      String fakeQuestion = "Loading decoy question...";
      
      try {
        // Fetch the fake questions from the new endpoint
        final response = await http.get(
          Uri.parse('https://nodejs-production-f031.up.railway.app/api/admin/fakeSecQst2'),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          List<dynamic> rows = data['rows'] ?? [];
          if (rows.isNotEmpty) {
            final random = Random();
            fakeQuestion = rows[random.nextInt(rows.length)]['fakeSecQst'] ?? "Unknown question?";
          }
        }
      } catch (e) {
        debugPrint('[DEBUG] Error fetching decoy: $e');
        fakeQuestion = "How many blue cars have you owned?"; 
      }

      setState(() {
        _selectedFirstQuestion = selected;
        
        // 1. Create the initial list of questions
        List<Map<String, String>> questionPool = [
          {'question': _allQuestions[x], 'id': 'q1'},
          {'question': _allQuestions[x + 30], 'id': 'q2'},
          {'question': _allQuestions[x + 60], 'id': 'q3'},
          {'question': fakeQuestion, 'id': 'q4_decoy'},
        ];

        // 2. SCRAMBLE logic: Shuffle the list using Dart's Random
        questionPool.shuffle(Random());

        // 3. Update state with the shuffled list
        _dynamicQuestions = questionPool;

        // 4. Initialize controllers and flags based on the new length (4)
        // We do this AFTER shuffling so the index of the controller 
        // matches the index of the shuffled question in the UI.
        _controllers = List.generate(4, (_) => TextEditingController());
        _skipFlags = List.generate(4, (_) => false);
        
        _isLoading = false;
      });
      
      debugPrint('[DEDUCTION] 4 questions (including decoy) loaded and scrambled.');
    }
  }

  Future<void> _loadRegions() async {
  try {
    final uri = Uri.parse('https://nodejs-production-53a4.up.railway.app/phone/regions');
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final List list = data['regions'] ?? [];
      final regs = list.map((e) => PhoneRegion.fromJson(e)).toList();
      setState(() {
        _regions = regs;
        // Default to UK or first available
        _selectedRegion = regs.firstWhere((r) => r.iso2 == 'GB', orElse: () => regs.first);
        _countryCodeCtrl.text = _selectedRegion!.code;
      });
    }
  } catch (e) {
    debugPrint("Region load error: $e");
  }
}

String iso2ToFlagEmoji(String iso2) {
  if (iso2.length != 2) return '';
  const int base = 0x1F1E6;
  final int a = base + (iso2.toUpperCase().codeUnitAt(0) - 0x41);
  final int b = base + (iso2.toUpperCase().codeUnitAt(1) - 0x41);
  return String.fromCharCodes([a, b]);
}

String? _validateStrong(String value, String label) {
  final v = value;

  // ✅ HARD MAX LENGTH GUARD (same pattern as username)
  if (v.characters.length > kPasswordMaxLen) {
    return '$label cannot exceed $kPasswordMaxLen characters.';
  }

  final missing = <String>[];

  if (v.characters.length < 8) missing.add('≥ 8 characters');
  if (!_upper.hasMatch(v)) missing.add('an uppercase letter');
  if (!_lower.hasMatch(v)) missing.add('a lowercase letter');
  if (!_digit.hasMatch(v)) missing.add('a number');
  if (!_symbol.hasMatch(v)) missing.add('a symbol');

  if (missing.isEmpty) return null;
  return '$label must include ${missing.join(', ')}.';
}
  
String? _validateIdentifier(String? value) {
  final v = (value ?? '').trim();

  switch (_idType) {
    case IdentifierType.username:
      if (v.isEmpty) return 'Username is required';

      // ✅ HARD length check first (prevents backend crash)
      if (v.characters.length > 100) {
        return 'Username cannot exceed 100 characters';
      }

      // ✅ Strong rules (existing logic)
      final strongErr = _validateStrong(v, 'Username');
      if (strongErr != null) return strongErr;

      return null;

    case IdentifierType.email:
      if (v.isEmpty) return 'Email is required';
      if (v.characters.length > kEmailMaxLen) {
        return 'Email must be ≤ $kEmailMaxLen characters';
      }
      if (!_email.hasMatch(v)) return 'Enter a valid email address';
      return null;

    case IdentifierType.phone:
      if (v.isEmpty) return 'Phone number is required';
      if (!_digitsOnly.hasMatch(v)) return 'Enter digits only';
      final r = _selectedRegion;
      if (r == null) return 'Choose a country';
      if (v.length < r.min || v.length > r.max) {
        return 'Expected ${r.min}-${r.max} digits for ${r.name}.';
      }
      return null;
  }
}


  // =============================================================
  // VALIDATION
  // =============================================================


  String? _validateQuestion(String? v, bool skipped) {
    if (skipped) return null;
    if (v == null || v.trim().isEmpty) {
      return "This question requires an answer or skip option.";
    }
    return null;
  }

  // 1. Add this variable to your _ForgotLoginPageState class
  String? _foundUserID;

  // 1. UPDATED SUBMISSION LOGIC
  void _handleFinalSubmission() async {
  if (!_formKey.currentState!.validate()) return;
  if (!_isHumanVerified) {
    _showFeedback("Please complete Human Verification first.");
    return;
  }

  try {
    await requireOnline<void>(
      context: context,
      task: () async {
        List<Map<String, String>> userAnswers = [];
        for (int i = 0; i < _dynamicQuestions.length; i++) {
          if (!_skipFlags[i]) {
            userAnswers.add({
              'q': _dynamicQuestions[i]['question']!,
              'a': _controllers[i].text.trim(),
            });
          }
        }

        if (userAnswers.length != 3) {
          _showFeedback("Please answer exactly 3 questions and mark 1 as unrecognized.");
          return;
        }

        setState(() => _isLoading = true);
        Map<String, dynamic>? matchedUser = await _findUserByAnswers(userAnswers);

        if (matchedUser != null) {
          _foundUserID = matchedUser['userID']?.toString();
          _promptForIdentifier(matchedUser);
        } else {
          _showFeedback("No account found matching these security answers.");
        }
        setState(() => _isLoading = false);
      },
    );
  } on OfflineException {
    // Handled by guard
  } catch (e) {
    setState(() => _isLoading = false);
    _showFeedback("Search error: $e");
  }
}

  // 2. SEARCH ALGORITHM (Updated with Null Safety Fixes)
  Future<Map<String, dynamic>?> _findUserByAnswers(
      List<Map<String, String>> provided) async {
    int currentPage = 1;
    bool hasMore = true;

    while (hasMore) {
      final response = await http.get(
        Uri.parse(
          'https://nodejs-production-f031.up.railway.app/api/admin/loginTable'
          '?page=$currentPage&pageSize=100',
        ),
      );

      if (response.statusCode != 200) break;

      final data = json.decode(response.body);
      List<dynamic> rows = data['rows'] ?? [];

      for (var row in rows) {
        // Map DB questions safely
        final List<Map<String, String>> dbPairs = [
          {
            'q': (row['secuQuestion1'] ?? '').toString(),
            'a': (row['secuAns1'] ?? '').toString(),
          },
          {
            'q': (row['secuQuestion2'] ?? '').toString(),
            'a': (row['secuAns2'] ?? '').toString(),
          },
          {
            'q': (row['secuQuestion3'] ?? '').toString(),
            'a': (row['secuAns3'] ?? '').toString(),
          },
        ];

        int matches = 0;

        for (var p in provided) {
          final bool foundMatch = dbPairs.any((db) =>
              db['q']!.trim().toLowerCase() ==
                  p['q']!.trim().toLowerCase() &&
              db['a']!.trim().toLowerCase() ==
                  p['a']!.trim().toLowerCase());

          if (foundMatch) matches++;
        }

        if (matches == 3) {
          /// ✅ MATCH FOUND — PRINT ACCOUNT DETAILS
          debugPrint('✅ [ACCOUNT FOUND]');
          debugPrint('UserID: ${row['userID']}');
          debugPrint('Username: ${row['username']}');
          debugPrint('Email: ${row['email']}');
          debugPrint(
              'Phone: ${row['phone_country_code'] ?? ''}${row['phone_number'] ?? ''}');
          debugPrint('Monthly Salary: ${row['monthlySalary']}');

          debugPrint('--- Matched Questions ---');
          for (final p in provided) {
            debugPrint('Q: ${p['q']} | A: ${p['a']}');
          }
          debugPrint('--------------------------');

          return row; // ✅ Return matched user
        }
      }

      // Pagination check
      if (rows.isEmpty ||
          (data['total'] != null && currentPage * 100 >= data['total'])) {
        hasMore = false;
      } else {
        currentPage++;
      }
    }

    debugPrint('❌ [NO MATCH FOUND]');
    return null;
  }

  // 1. MAIN IDENTIFIER VERIFICATION DIALOG
  // =============================================================
  // UPDATED: INTERNET-AWARE IDENTIFIER VERIFICATION
  // =============================================================
  void _promptForIdentifier(Map<String, dynamic> userData) async {
    try {
      // Check for internet connection before showing the hint dialog
      await requireOnline<void>(
        context: context,
        task: () async {
          final String? username = userData['username']?.toString();
          final bool hasUsername = username != null && username.isNotEmpty;

          if (hasUsername) {
            // Phase 1: Show Hint first (Only if online)
            _showUsernameHintDialog(userData);
          } else {
            // No username on file: Go straight to Salary Verification
            _showSalaryVerification(userData);
          }
        },
      );
    } on OfflineException {
      // API Guard handles the "You are offline" dialog automatically.
      // We stop execution here so the Username Hint never appears.
      debugPrint('[OFFLINE] Prevented identifier prompt due to no connection.');
    } catch (e) {
      _showFeedback("An error occurred during verification: $e");
    }
  }

  void _showUsernameHintDialog(Map<String, dynamic> userData) {
  String rawUsername = userData['username'].toString();
  
  // Create a hint: "m*******e"
  String hint = rawUsername.length > 2 
      ? "${rawUsername[0]}${'*' * (rawUsername.length - 2)}${rawUsername[rawUsername.length - 1]}"
      : "**";

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text("Username Hint"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("We found an account matching your answers."),
          const SizedBox(height: 10),
          Text("Does this look familiar?  $hint", 
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, letterSpacing: 2)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            _showSalaryVerification(userData);
          },
          child: const Text("I don't recognize this"),
        ),
        ElevatedButton(
          onPressed: () async {
            // NEW: Detect internet before opening the verification input
            try {
              await requireOnline<void>(
                context: context,
                task: () async {
                  Navigator.pop(context); // Close Hint Dialog
                  _showUsernameVerification(userData); // Proceed to input
                },
              );
            } on OfflineException {
              // The requireOnline helper already shows the "No Internet" UI.
              // We do nothing else; the Hint Dialog remains open for retry.
              debugPrint('[OFFLINE] Blocked transition to Username Verification.');
            }
          },
          child: const Text("Yes, I remember!"),
        ),
      ],
    ),
  );
}

  // 2. USERNAME VERIFICATION FLOW
  void _showUsernameVerification(Map<String, dynamic> userData) {
  final TextEditingController usernameController = TextEditingController();
  String rawUsername = userData['username'].toString();

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text("Verify Username"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Please enter the full username to receive your temporary password."),
          const SizedBox(height: 16),
          TextField(
            controller: usernameController,
            decoration: const InputDecoration(
              labelText: "Full Username",
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context), 
          child: const Text("Back")
        ),
        ElevatedButton(
          onPressed: () {
            if (usernameController.text.trim() == rawUsername) {
              Navigator.pop(context);
              _showRecoveryPassword(rawUsername);
            } else {
              _showFeedback("Username mismatch. Try again or go back.");
            }
          },
          child: const Text("Verify & Login"),
        ),
      ],
    ),
  );
}

  // 3. SALARY VERIFICATION FLOW
  void _showSalaryVerification(Map<String, dynamic> userData) {
    final TextEditingController salaryController = TextEditingController();
    bool salaryNotProvided = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setStepState) => AlertDialog(
          title: const Text("Verify Monthly Salary"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("This account has no username. Please input your monthly salary regardless the currency to proceed."),
              const SizedBox(height: 16),
              if (!salaryNotProvided)
                TextField(
                  controller: salaryController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "Monthly Salary",
                    border: OutlineInputBorder(),
                  ),
                ),
              Row(
                children: [
                  Checkbox(
                    value: salaryNotProvided,
                    onChanged: (val) => setStepState(() => salaryNotProvided = val!),
                  ),
                  const Text("I did not provide a salary."),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () {
                var dbSalary = userData['monthlySalary'];
                bool isMatch = false;

                if (salaryNotProvided) {
                  isMatch = (dbSalary == null);
                } else {
                  isMatch = (dbSalary?.toString() == salaryController.text.trim());
                }

                if (isMatch) {
                  Navigator.pop(context);
                  _showNewCredentialsDialog();
                } else {
                  _showFeedback("Salary verification failed.");
                }
              },
              child: const Text("Verify"),
            ),
          ],
        ),
      ),
    );
  }

  // 4. DISPLAY GENERATED PASSWORD (Path A)
  void _showRecoveryPassword(String username) async {
    // Generate a simple random temporary password
    String tempPass = Random().nextInt(999999).toString().padLeft(6, '0');
    
    setState(() => _isLoading = true);

    // PERFORM THE DATABASE UPDATE VIA API
    bool success = await _updatePasswordInDatabase(_foundUserID, tempPass);

    setState(() => _isLoading = false);

    if (!success) {
      _showFeedback("Failed to update password on server. Please try again.");
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Account Recovered"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Access granted. Your password has been reset."),
            const SizedBox(height: 16),
            Text("Username: $username", style: const TextStyle(fontWeight: FontWeight.bold)),
            Text("New Password: $tempPass", 
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 18)),
            const SizedBox(height: 10),
            const Text("Use these credentials to log in now.", style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        // Inside _showRecoveryPassword(...) actions:
        actions: [
          TextButton(
            onPressed: () {
              // Return to Login Page
              Navigator.of(context).pop(); // Close Dialog
              Navigator.of(context).pop(); // Close ForgotLoginPage
            }, 
            child: const Text("Done")
          ),
        ],
      ),
    );
  }

  Future<bool> _updatePasswordInDatabase(String? userId, String newPassword) async {
  if (userId == null) return false;

  try {
    final response = await http.put(
      Uri.parse('https://nodejs-production-f031.up.railway.app/api/admin/update-password'),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "userID": userId,
        "newPassword": newPassword,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['ok'] == true;
    }
    return false;
  } catch (e) {
    debugPrint("Update Password Error: $e");
    return false;
  }
}
  
  Future<void> _updateUserIdentity({
  required String? userId,
  required IdentifierType type,
  required String identifier,
  required String password,
  String? countryCode,
}) async {
  if (userId == null) {
    debugPrint('❌ userId is null – aborting update');
    return;
  }

  // --- LOGIC: COUNT AND DETECT ---
  final int passwordLength = password.characters.length;
  debugPrint('--- [DEBUG: IDENTITY UPDATE] ---');
  debugPrint('Target UserID: $userId');
  debugPrint('Detected Password Length: $passwordLength');
  
  // 1. Client-Side Safety Guard
  if (passwordLength > kPasswordMaxLen) {
    debugPrint('🛑 STOP: Password is $passwordLength chars (Limit: $kPasswordMaxLen)');
    _showFeedback('Local Error: Password ($passwordLength) exceeds limit ($kPasswordMaxLen).');
    return;
  }

  final uri = Uri.parse('https://nodejs-production-f031.up.railway.app/api/user/update-identity');

  final payload = {
    'userID': userId,
    'username': type == IdentifierType.username ? identifier : null,
    'email': type == IdentifierType.email ? identifier : null,
    'phone_number': type == IdentifierType.phone ? identifier : null,
    'phone_country_code': type == IdentifierType.phone ? countryCode : null,
    'password': password,
  };

  debugPrint('📤 SENDING PAYLOAD: ${jsonEncode(payload)}');
  setState(() => _isLoading = true);

  try {
    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    debugPrint('📥 SERVER RESPONSE CODE: ${response.statusCode}');
    debugPrint('📥 SERVER RESPONSE BODY: ${response.body}');

    Map<String, dynamic>? data;
    try {
      data = jsonDecode(response.body);
    } catch (e) {
      debugPrint('⚠️ Response is NOT valid JSON');
    }

    if (response.statusCode == 200 && data?['ok'] == true) {
      _showFinalSuccessDialog(identifier);
    } else {
      // 2. Map Backend Error (invalid_password_length)
      String errorMsg = data?['message'] ?? 'An unknown error occurred.';
      _showFeedback('Server Rejected: $errorMsg');
    }

  } catch (e) {
    debugPrint('🔥 EXCEPTION: $e');
    _showFeedback('Connection error: $e');
  } finally {
    setState(() => _isLoading = false);
  }
}

  void _showNewCredentialsDialog() {
    final TextEditingController idCtrl = TextEditingController();
    final TextEditingController passCtrl = TextEditingController();
    final dialogKey = GlobalKey<FormState>();

    bool showPassword = false; 

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setStepState) {
          final theme = Theme.of(context);

          return AlertDialog(
            title: const Text("Reset Account Details"),
            content: SingleChildScrollView(
              child: Form(
                key: dialogKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildTypeRadio(setStepState, "User", IdentifierType.username),
                        _buildTypeRadio(setStepState, "Email", IdentifierType.email),
                        _buildTypeRadio(setStepState, "Phone", IdentifierType.phone),
                      ],
                    ),
                    const SizedBox(height: 20),

                    _buildIdentifierField(theme, idCtrl, setStepState),

                    const SizedBox(height: 15),

                    // ✅ UPDATED PASSWORD FIELD
                    // Inside _showNewCredentialsDialog -> StatefulBuilder -> TextFormField for password
                    TextFormField(
                      controller: passCtrl,
                      obscureText: !showPassword,
                      // PHYSICAL RESTRAINT:
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(kPasswordMaxLen), // 254
                      ],
                      decoration: InputDecoration(
                        labelText: "New Password",
                        counterText: "", // Hides the counter but still enforces the limit
                        border: const OutlineInputBorder(),
                        prefixIcon: IconButton(
                          icon: Icon(showPassword ? Icons.lock_open : Icons.lock),
                          onPressed: () => setStepState(() => showPassword = !showPassword),
                        ),
                      ),
                      validator: (v) {
                        final value = v ?? '';
                        if (value.characters.length > kPasswordMaxLen) {
                          return 'Password too long (${value.characters.length}/$kPasswordMaxLen)';
                        }
                        return _validateStrong(value, 'Password');
                      },
                    ),

                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: () {
                  // Only proceeds to API call if validation returns null
                  if (dialogKey.currentState!.validate()) {
                    Navigator.pop(context);

                    _updateUserIdentity(
                      userId: _foundUserID,
                      type: _idType,
                      identifier: idCtrl.text.trim(),
                      password: passCtrl.text.trim(),
                      countryCode:
                          _idType == IdentifierType.phone
                              ? _countryCodeCtrl.text
                              : null,
                    );
                  }
                },
                child: const Text("Save & Finish"),
              ),
            ],
          );
        },
      ),
    );
  }

  // Helper for the radio toggle
  Widget _buildTypeRadio(StateSetter setState, String label, IdentifierType type) {
    return InkWell(
      onTap: () => setState(() => _idType = type),
      child: Column(
        children: [
          Radio<IdentifierType>(
            value: type,
            groupValue: _idType,
            onChanged: (v) => setState(() => _idType = v!),
          ),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  // Helper for the radio toggle in the dialog
  Widget _buildTypeOption(StateSetter setState, String label, IdentifierType type) {
    return GestureDetector(
      onTap: () => setState(() => _idType = type),
      child: Column(
        children: [
          Radio<IdentifierType>(
            value: type,
            groupValue: _idType,
            onChanged: (v) => setState(() => _idType = v!),
          ),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildIdentifierField(ThemeData theme, TextEditingController controller, StateSetter setStepState) {
    // Determine if phone mode is active to show the country code picker
    final bool isPhone = _idType == IdentifierType.phone;

    return TextFormField(
      controller: controller,
      // Switch keyboard type to phone if needed, or multiline to allow the "Enter" key
      keyboardType: isPhone ? TextInputType.phone : TextInputType.multiline,
      
      // --- EXPANDABLE UI LOGIC ---
      // null maxLines allows the field to grow vertically as the user types
      maxLines: isPhone ? 1 : null, 
      minLines: 1, 
      // ---------------------------

      decoration: InputDecoration(
        labelText: isPhone ? "Phone Number" : (_idType == IdentifierType.email ? "Email" : "Username"),
        // Ensures the label stays at the top when the box expands
        alignLabelWithHint: true, 
        
        // Add the country code dropdown as a prefix icon if in phone mode
        prefixIcon: isPhone
            ? Container(
                width: 140,
                padding: const EdgeInsets.only(left: 8),
                child: DropdownSearch<PhoneRegion>(
                  items: (filter, loadProps) => _regions,
                  selectedItem: _selectedRegion,
                  compareFn: (a, b) => a.iso2 == b.iso2,
                  itemAsString: (r) {
                    final flag = iso2ToFlagEmoji(r.iso2);
                    final pretty = r.displayCode ?? r.code;
                    return '${flag.isNotEmpty ? '$flag ' : ''}${r.name} ($pretty)';
                  },
                  decoratorProps: const DropDownDecoratorProps(
                    decoration: InputDecoration(
                      border: InputBorder.none,
                    ),
                  ),
                  popupProps: const PopupProps.menu(
                    showSearchBox: true,
                    searchFieldProps: TextFieldProps(
                      decoration: InputDecoration(
                        hintText: 'Search country or code…',
                      ),
                    ),
                  ),
                  onChanged: (r) {
                    setStepState(() {
                      _selectedRegion = r;
                      if (r != null) _countryCodeCtrl.text = r.code;
                    });
                  },
                ),
              )
            : Icon(
                _idType == IdentifierType.email
                    ? Icons.email
                    : Icons.person,
              ),

        border: const OutlineInputBorder(),
        hintText: isPhone ? "e.g. 7123456789" : "Enter your identifier",
      ),
      // Use the comprehensive validator logic from signup_page
      validator: (v) {
        final raw = (v ?? '').trim();
        if (raw.isEmpty) return 'This field is required';

        if (isPhone) {
          // 1. Ensure only digits are entered
          if (!_digitsOnly.hasMatch(raw)) {
            return 'Enter digits only';
          }

          // 2. Validate length based on the selected country's database rules
          final r = _selectedRegion;
          if (r != null) {
            if (raw.length < r.min || raw.length > r.max) {
              return 'Expected ${r.min}-${r.max} digits for ${r.name}.';
            }
          }
        } else if (_idType == IdentifierType.email) {
          // Standard email validation
          if (!_email.hasMatch(raw)) return 'Enter a valid email address';
          if (raw.length > kEmailMaxLen) return 'Email is too long';
        } else {
          // Username strength validation
          // ✅ HARD length limit BEFORE sending to backend
          if (raw.characters.length > 100) {
            return 'Username cannot exceed 100 characters';
          }
          return _validateStrong(raw, 'Username');

        }
        return null;
      },
    );
  }
  // Simplified Success Dialog
  void _showFinalSuccessDialog(String confirmedValue) {
  showDialog(
    context: context,
    barrierDismissible: false, // Force them to click the button
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green),
          SizedBox(width: 10),
          Text("Success"),
        ],
      ),
      content: Text("Identity verified. This is the related phone number/email $confirmedValue. Click the button to return to login."),
      actions: [
        TextButton(
          onPressed: () {
            // This pops the dialog AND the forgot password page 
            // to return to the underlying login_page.dart
            Navigator.of(context).pop(); // Close Dialog
            Navigator.of(context).pop(); // Close ForgotLoginPage
          }, 
          child: const Text("Back to Login")
        ),
      ],
    ),
  );
}

  // 4. MASKING AND FINAL SUCCESS
  void _showMaskedConfirmation(Map<String, dynamic> user, String confirmedValue) {
    String mask(String? val) {
      if (val == null || val.length < 4) return "****";
      return "${val.substring(0, 2)}****${val.substring(val.length - 2)}";
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Final Step"),
        content: Text("Account verified. We will send recovery instructions to: \n\n${mask(confirmedValue)}"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Finish")),
        ],
      ),
    );
  }

  // =============================================================
  // HUMAN VERIFICATION LOGIC
  // =============================================================
  void _startHolding() {
    setState(() {
      _holding = true;
      _currentSeconds = 0;
      _readyToRelease = false;
    });

    _holdWatch..reset()..start();

    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!_holding) {
        t.cancel();
        return;
      }
      setState(() {
        _currentSeconds++;
        if (_currentSeconds >= _requiredSeconds) {
          _readyToRelease = true;
        }
      });
    });
  }

  void _stopHolding() {
  // If we are already in the "waiting" period after a failure, do nothing
  if (_isProcessingTest) return;

  _timer?.cancel();
  _holdWatch.stop();
  final int elapsedMs = _holdWatch.elapsedMilliseconds;

  setState(() {
    _holding = false;
    _readyToRelease = false;
  });

  final int minMs = _requiredSeconds * 1000;
  final int maxMs = (_requiredSeconds + _graceSeconds) * 1000;

  if (elapsedMs < minMs || elapsedMs > maxMs) {
    // FAILURE CASE
    setState(() {
      _isHumanVerified = false;
      _isProcessingTest = true; // Lock the button
    });

    String errorMsg = elapsedMs < minMs 
        ? "Failed: Released too early (${(elapsedMs / 1000).toStringAsFixed(1)}s)." 
        : "Failed: Held for too long.";

    _showFeedback(errorMsg);

    // Wait 3 seconds for the user to read the SnackBar before resetting
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isProcessingTest = false; // Unlock the button
          _currentSeconds = 0;       // Reset visual counter
          _generateRequiredSeconds(); // Generate new target
        });
      }
    });
  } else {
    // SUCCESS CASE
    setState(() {
      _isHumanVerified = true;
      _isProcessingTest = false;
    });
  }
}

  void _showFeedback(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // =============================================================
  // BUILD UI
  // =============================================================
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Forgot Login Details"),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // NEW: Connection status hint added at the top (Matches login_page.dart)
                      _connectionHint(),
                      const SizedBox(height: 16),

                      Text(
                        "Identify your account by selecting your first security question. (contact support from ka4.au@live.uwe.ac.uk)",
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 16),

                      // 1. QUESTION SELECTION DROPDOWN
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: _selectedFirstQuestion,
                        hint: const Text("Select your first security question"),
                        decoration: const InputDecoration(
                          labelText: "Security Question 1",
                          border: OutlineInputBorder(),
                          filled: true,
                        ),
                        items: _primaryQuestions.isEmpty 
                          ? [] 
                          : _primaryQuestions.map((q) {
                              return DropdownMenuItem(
                                value: q,
                                child: Text(q, overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                        onChanged: (val) {
                          _onFirstQuestionSelected(val);
                        },
                        validator: (v) => v == null ? "Please select a question" : null,
                      ),

                      const SizedBox(height: 24),

                      // 2. DYNAMICALLY DEDUCED QUESTIONS
                      if (_selectedFirstQuestion != null) ...[
                        const Divider(),
                        const SizedBox(height: 16),
                        Text(
                          "Please provide the answers for your assigned questions:",
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 20),
                        
                        ...List.generate(_dynamicQuestions.length, (index) {
                          final qData = _dynamicQuestions[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: _questionItem(
                              label: "${index + 1}. ${qData['question']}",
                              controller: _controllers[index],
                              skipFlag: _skipFlags[index],
                              onSkipChanged: (bool v) {
                                setState(() => _skipFlags[index] = v);
                              },
                            ),
                          );
                        }),

                        const SizedBox(height: 20),
                        
                        // 3. HUMAN VERIFICATION SECTION
                        _humanTestSection(),

                        const SizedBox(height: 30),

                        // 4. FINAL VERIFICATION BUTTON
                        FilledButton.icon(
                          onPressed: _handleFinalSubmission,
                          icon: const Icon(Icons.verified_user),
                          label: const Text("Verify Answers & Submit"),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: _isHumanVerified ? Colors.green : null,
                          ),
                        ),
                                                
                        const SizedBox(height: 40),
                      ] else ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              "Select your first question above to proceed.",
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _questionItem({
    required String label,
    required TextEditingController controller,
    required bool skipFlag,
    required ValueChanged<bool> onSkipChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),

        if (!skipFlag)
          TextFormField(
            controller: controller,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: "Type your answer",
            ),
            validator: (v) => _validateQuestion(v, skipFlag),
          ),
        const SizedBox(height: 4),

        Row(
          children: [
            Checkbox(
              value: skipFlag,
              onChanged: (v) => onSkipChanged(v!),
            ),
            const Text("This question was not there when I signed up."),
          ],
        ),
      ],
    );
  }

  Widget _humanTestSection() {
    return Column(
      key: humanTestKey,
      children: [
        const Text(
          "Human Verification",
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: Color(0xFF333333)),
        ),
        const SizedBox(height: 8),
        Text(
          "Press & hold for ~$_requiredSeconds seconds, then release.",
          style: const TextStyle(fontSize: 14, color: Color(0xFF444444)),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          // Disable interactions if verified OR if currently showing a failure message
          onLongPressStart: (_isHumanVerified || _isProcessingTest) 
              ? null 
              : (_) => _startHolding(),
          onLongPressEnd: (_isHumanVerified || _isProcessingTest) 
              ? null 
              : (_) => _stopHolding(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 280,
            height: 90,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Keep your original colors and styling
              color: _isHumanVerified ? Colors.green : const Color(0xFF2196F3),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isHumanVerified ? Icons.check : Icons.fingerprint,
                  color: Colors.white,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Text(
                  _isHumanVerified
                      ? "VERIFIED"
                      : "HOLD: $_currentSeconds / $_requiredSeconds",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _isHumanVerified ? null : _generateRequiredSeconds,
          child: const Text(
            "Reset Timer",
            style: TextStyle(color: Color(0xFF5C5C8C), fontSize: 16),
          ),
        ),
      ],
    );
  }
}