
// lib/login_page.dart
// Updated: Mirrors signup entry UI (IdentifierType radios + country dropdown for Phone),
// posts explicit identifierType to /api/login, and supplies phone_country_code + phone_number.
// Keeps your connection hint, pill actions, and masked logging.
//
// Depends on: http, internet_connection_checker, api_guard.dart (requireOnline/OfflineException)
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'api_guard.dart';
// NEW IMPORT (ONLY CHANGE ADDED)
import 'home_page.dart';

import 'forgot_login_page.dart';

import 'package:dropdown_search/dropdown_search.dart';

// ==== API bases (aligned with your existing files) ====
const String kApiBase = 'https://nodejs-production-53a4.up.railway.app'; // phone regions/validation
const String kApiAuthBase = 'https://nodejs-production-f031.up.railway.app'; // signup/login backend
const String kApiKey = ''; // optional

// Identifier type — same as signup
enum IdentifierType { username, email, phone }

// ---- PhoneRegion model (identical to signup) ----
class PhoneRegion {
  final String iso2;
  final String name;
  /// canonical '+<digits>'
  final String code;
  final String? displayCode;
  final int min;
  final int max;

  const PhoneRegion({
    required this.iso2,
    required this.name,
    required this.code,
    this.displayCode,
    required this.min,
    required this.max,
  });

  factory PhoneRegion.fromJson(Map<String, dynamic> j) => PhoneRegion(
        iso2: _toAlpha2((j['iso2'] ?? '').toString()),
        name: (j['name'] ?? '').toString(),
        code: (j['code'] ?? '').toString(),
        displayCode: j['displayCode'] as String?,
        min: (j['min'] ?? 0) as int,
        max: (j['max'] ?? 0) as int,
      );
}

// Convert emoji flag or raw to "GB"
String _toAlpha2(String input) {
  final t = input.trim();
  if (RegExp(r'^[A-Za-z]{2}$').hasMatch(t)) return t.toUpperCase();
  final runes = t.runes.toList();
  if (runes.length == 2 &&
      runes.every((cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF)) {
    final a = String.fromCharCode(0x41 + (runes[0] - 0x1F1E6));
    final b = String.fromCharCode(0x41 + (runes[1] - 0x1F1E6));
    return '$a$b';
  }
  return t.toUpperCase();
}

// Simple helper to show flags from ISO2
String iso2ToFlagEmoji(String iso2) {
  if (iso2.length != 2) return '';
  const int base = 0x1F1E6;
  final up = iso2.toUpperCase();
  final int a = base + (up.codeUnitAt(0) - 0x41);
  final int b = base + (up.codeUnitAt(1) - 0x41);
  return String.fromCharCodes([a, b]);
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  IdentifierType _idType = IdentifierType.username;

  // Inputs
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  // Phone region state (same pattern as signup)
  List<PhoneRegion> _regions = const [];
  PhoneRegion? _selectedRegion;
  String? _regionsError;

  bool _isSubmitting = false;
  bool _obscure = true;

  final RegExp _email = RegExp(r'^\S+@\S+\.\S{2,}$');
  final RegExp _digitsOnly = RegExp(r'^\d{1,20}$');

  @override
  void initState() {
    super.initState();
    _loadRegions();
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ---- Load phone regions ----
  Future<void> _loadRegions() async {
    try {
      final uri = Uri.parse('$kApiBase/phone/regions');
      final headers = <String, String>{'Accept': 'application/json'};
      if (kApiKey.isNotEmpty) headers['x-api-key'] = kApiKey;
      final res = await http.get(uri, headers: headers).timeout(
            const Duration(seconds: 10),
          );
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body);
      final List list = data['regions'] ?? [];
      final regs = list
          .map((e) => PhoneRegion.fromJson(e as Map<String, dynamic>))
          .toList()
          .cast<PhoneRegion>();
      setState(() {
        _regions = regs;
        if (regs.isNotEmpty) {
          final gb = regs.where((r) => r.iso2.toUpperCase() == 'GB');
          _selectedRegion = gb.isNotEmpty ? gb.first : regs.first;
        }
        _regionsError = null;
      });
    } catch (_) {
      setState(() {
        _regionsError = 'Could not load countries. Using default +44.';
        _selectedRegion ??= const PhoneRegion(
          iso2: 'GB',
          name: 'United Kingdom',
          code: '+44',
          displayCode: '+44',
          min: 10,
          max: 10,
        );
      });
    }
  }

  // ---- UI helper widgets ----
  Widget _connectionHint() {
    return StreamBuilder<InternetConnectionStatus>(
      stream: InternetConnectionChecker().onStatusChange,
      initialData: InternetConnectionStatus.connected,
      builder: (context, snap) {
        final offline = snap.data == InternetConnectionStatus.disconnected;
        return Row(
          children: [
            Icon(
              offline ? Icons.wifi_off : Icons.wifi,
              size: 18,
              color: offline ? Theme.of(context).colorScheme.error : null,
              semanticLabel: offline ? 'Offline' : 'Online',
            ),
            const SizedBox(width: 6),
            Text(
              offline
                  ? 'You’re offline. Connect to the internet to log in.'
                  : 'Connected to the internet.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }

  Widget _pillAction({
    required String label,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        foregroundColor: theme.colorScheme.primary,
        side: BorderSide(color: theme.colorScheme.outline),
        shape: const StadiumBorder(),
        textStyle: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      child: Text(label),
    );
  }

  void _onIdTypeChanged(IdentifierType v) {
    if (_idType == v) return;
    setState(() {
      _idType = v;
      _identifierCtrl.clear();
    });
  }

  // ---- Validators ----
  String? _validateIdentifier(String? value) {
    final v = (value ?? '').trim();
    switch (_idType) {
      case IdentifierType.username:
        if (v.isEmpty) return 'Username is required';
        return null;
      case IdentifierType.email:
        if (v.isEmpty) return 'Email is required';
        if (!_email.hasMatch(v)) return 'Please enter a valid email address';
        return null;
      case IdentifierType.phone:
        if (v.isEmpty) return 'Phone number is required';
        if (!_digitsOnly.hasMatch(v)) return 'Enter digits only';
        final r = _selectedRegion;
        if (r == null) return 'Choose a country';
        if (v.length < r.min || v.length > r.max) {
          return 'Expected ${r.min}-${r.max} digits for ${r.name} (excluding country code).';
        }
        return null;
    }
  }

  String? _validatePassword(String? v) {
    if ((v ?? '').isEmpty) return 'Please enter your password';
    return null;
  }

  // ---- LOGIN SUBMIT ----
  Future<void> _onLogin() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.')),
      );
      return;
    }
    try {
      await requireOnline<void>(
        context: context,
        task: () async {
          setState(() => _isSubmitting = true);

          final idRaw = _identifierCtrl.text.trim();
          final Map<String, dynamic> body = {
            'identifierType': _idType.name,
            'identifier': idRaw,
            'password': _passwordCtrl.text,
          };
          if (_idType == IdentifierType.phone) {
            final r = _selectedRegion;
            body['phone_country_code'] = r?.code ?? '+44';
            body['phone_number'] = idRaw;
          }

          final uri = Uri.parse('$kApiAuthBase/api/login');
          final headers = <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          };
          if (kApiKey.isNotEmpty) headers['x-api-key'] = kApiKey;

          final safeBody = {...body, 'password': '***'};
          print('======== LOGIN ========');
          print('[POST] $uri');
          print('[BODY] $safeBody');
          final res = await http
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 10));
          print('[STATUS] ${res.statusCode}');
          print('[RESPONSE] ${res.body}');
          print('=======================');

          setState(() => _isSubmitting = false);

          // Navigate to Home on success
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            final userId = (data['userID'] ?? '').toString();

            // NEW: include how the user signed in + the identifier value they used
            final idType = _idType.name; // "username" | "email" | "phone"
            String idValue = _identifierCtrl.text.trim();
            if (_idType == IdentifierType.phone) {
              final cc = _selectedRegion?.code ?? '+44';
              idValue = '$cc $idValue'; // display-friendly
            }

            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => HomePage(
                  userId: userId,
                  identifierType: idType,
                  identifierValue: idValue,
                ),
              ),
            );
            return;
          }

          // Existing error‑handling
          String errorMsg = 'Login failed. Please try again.';
          try {
            final data = jsonDecode(res.body);
            final err = (data['error'] ?? '').toString();
            if (err == 'identifier_not_found') {
              errorMsg = _idType == IdentifierType.phone
                  ? 'Phone not found.'
                  : (_idType == IdentifierType.email
                      ? 'Email not found.'
                      : 'Username not found.');
            } else if (err == 'invalid_password') {
              errorMsg = 'Invalid password.';
            } else if (err == 'invalid_phone_number') {
              errorMsg = 'Invalid phone number.';
            }
          } catch (_) {}
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(errorMsg)),
          );
        },
      );
    } on OfflineException {
      // requireOnline handles this
    } catch (_) {
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  // ---- Identifier field builder ----
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
        formatters = [FilteringTextInputFormatter.digitsOnly];
        break;
      case IdentifierType.username:
      default:
        label = 'Username';
        hint = 'ie: chris';
        icon = Icons.person_outline;
        type = TextInputType.text;
        hints = const [AutofillHints.username];
    }

    final helperTextForField =
        _idType == IdentifierType.phone && _selectedRegion != null
            ? 'Expected ${_selectedRegion!.min}-${_selectedRegion!.max} digits for ${_selectedRegion!.name} (excluding country code).'
            : null;

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
        errorMaxLines: 4,
        helperMaxLines: 3,
      ),
      validator: _validateIdentifier,
      onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
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
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.spa_outlined,
                            color: theme.colorScheme.primary),
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
                    _connectionHint(),
                    const SizedBox(height: 12),
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHigh,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'Welcome. Choose how you want to log in, then enter your details.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Identifier type
                    Wrap(
                      spacing: 16,
                      children: [
                        _radioItem('Username', IdentifierType.username),
                        _radioItem('Email', IdentifierType.email),
                        _radioItem('Phone number', IdentifierType.phone),
                      ],
                    ),
                    const SizedBox(height: 12),

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
                                  // Fixed: 'items' is the correct parameter for a static list
                                  items: (filter, loadProps) => _regions, 
                                  selectedItem: _selectedRegion,
                                  
                                  // ADD THIS LINE: Tells the widget how to check if two regions are the same
                                  compareFn: (item1, item2) => item1.iso2 == item2.iso2,

                                  itemAsString: (r) {
                                    final flag = iso2ToFlagEmoji(r.iso2);
                                    final pretty = r.displayCode ?? r.code;
                                    return '${flag.isNotEmpty ? '$flag ' : ''}${r.name} ($pretty)';
                                  },
                                  // Fixed: 'dropdownDecoratorProps' changed to 'decoratorProps'
                                  decoratorProps: DropDownDecoratorProps(
                                    // Fixed: 'dropdownSearchDecoration' changed to 'decoration'
                                    decoration: InputDecoration(
                                      labelText: 'Country',
                                      prefixIcon: const Icon(Icons.flag_outlined),
                                      helperText: _regionsError,
                                      filled: true,
                                      fillColor: theme.colorScheme.surface,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
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
                                  validator: (r) {
                                    if (_idType != IdentifierType.phone) return null;
                                    return r == null ? 'Choose a country' : null;
                                  },
                                  onChanged: (r) => setState(() => _selectedRegion = r),
                                ),
                                                                
                                const SizedBox(height: 8),
                                _identifierField(theme),
                              ],
                            )
                          else
                            _identifierField(theme),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordCtrl,
                            obscureText: _obscure,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              hintText: 'Enter your password',
                              prefixIcon:
                                  const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                onPressed: () => setState(
                                    () => _obscure = !_obscure),
                                icon: Icon(_obscure
                                    ? Icons.visibility_off
                                    : Icons.visibility),
                                tooltip: _obscure
                                    ? 'Show password'
                                    : 'Hide password',
                              ),
                              filled: true,
                              fillColor: theme.colorScheme.surface,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            validator: _validatePassword,
                            onFieldSubmitted: (_) => _onLogin(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _pillAction(
                            label: 'No Account? Set up one today',
                            onPressed: () =>
                                Navigator.pushNamed(context, '/signup'),
                          ),
                          const SizedBox(height: 8),
                          _pillAction(
                            label: 'Forget your login details',
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const ForgotLoginPage()),
                              );
                            },
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _isSubmitting ? null : _onLogin,
                        icon: _isSubmitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.login),
                        label: Text(_isSubmitting ? 'Logging in…' : 'Log In'),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          foregroundColor:
                              theme.colorScheme.onPrimaryContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
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
        child: const Icon(Icons.menu, semanticLabel: 'Menu'),
      ),
    );
  }

  Widget _radioItem(String label, IdentifierType value) {
    return InkWell(
      onTap: () => _onIdTypeChanged(value),
      borderRadius: BorderRadius.circular(20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Radio<IdentifierType>(
            value: value,
            groupValue: _idType,
            onChanged: (v) => _onIdTypeChanged(v!),
          ),
          Text(label),
        ],
      ),
    );
  }
}
