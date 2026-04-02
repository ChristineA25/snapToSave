
// main.dart
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
// If you use the common plugin, import image_gallery_saver instead:
// import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

// ML Kit packages
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

// Service to fetch shop names for Source dropdown
import 'shop_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photo Taking + Vision',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const CaptureAndRecognizePage(title: 'Offline Vision (No API Keys8)'),
    );
  }
}

class CaptureAndRecognizePage extends StatefulWidget {
  const CaptureAndRecognizePage({super.key, required this.title});
  final String title;

  @override
  State<CaptureAndRecognizePage> createState() => _CaptureAndRecognizePageState();
}

class _CaptureAndRecognizePageState extends State<CaptureAndRecognizePage> {
  // UI & storage
  final ImagePicker _picker = ImagePicker();
  File? _imageFile;

  /// Unified list of results saved to DB: rows with {type, description, score?, bbox?}
  List<Map<String, dynamic>> _labels = [];
  Database? _db;

  // Busy flag to prevent double-actions while processing
  bool _isBusy = false;

  // ML Kit detectors
  late final ObjectDetector _objectDetector;
  late final TextRecognizer _textRecognizer;
  late final ImageLabeler _imageLabeler; // optional fine-grained labels

  // --- Price per row state (index -> chosen price string) ---
  final Map<int, String> _rowPrices = {};

  // --- Source dropdown state ---
  List<String> _sourceOptions = []; // values pulled from MySQL (e.g., chainShop.shopName)
  String? _sourceLoadError; // remember load error text (shown as a banner)
  final Map<int, String> _rowSources = {}; // rowIndex -> chosen Source value (custom or from list)

  // Remote service for shops (replace URL with your own if needed)
  final _shopService = ShopService(
    'https://nodejs-production-53a4.up.railway.app/', // TODO: replace with your real Railway URL
    // apiKey: null,
  );

  // Natural image pixel size for accurate overlay scaling
  Size? _imagePixelSize;

  // Horizontal ScrollController for the results table area
  final ScrollController _hScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _initDb();
    _initDetectors();
    _loadSourceOptions(); // load dropdown options for Source on startup
  }

  @override
  void dispose() {
    _hScrollCtrl.dispose();
    _objectDetector.close();
    _textRecognizer.close();
    _imageLabeler.close();
    super.dispose();
  }

  Future<void> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'photobook.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL,
            taken_at INTEGER NOT NULL,
            labels_json TEXT
          )
        ''');
      },
    );
  }

  void _initDetectors() {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,
      multipleObjects: true,
    );
    _objectDetector = ObjectDetector(options: options);
    _textRecognizer = TextRecognizer();
    _imageLabeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.3),
    );
  }

  // --- Load Source options from server (do NOT disable per-row UI if this fails) ---
  Future<void> _loadSourceOptions() async {
    // optimistic: clear previous error so dropdowns stay interactive
    if (mounted) setState(() => _sourceLoadError = null);
    try {
      final values = await _shopService.fetchShops();
      if (!mounted) return;
      setState(() {
        _sourceOptions = values.where((v) => v.trim().isNotEmpty).toList();
        _sourceLoadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final msg = e is TimeoutException
            ? 'Source server took too long to respond (might be cold-starting). Please Retry.'
            : 'Failed to load Source options: $e';
        _sourceLoadError = msg;
        _sourceOptions = [];
      });
    }
  }

  Future<void> _loadImagePixelSize(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, (img) => completer.complete(img));
      final img = await completer.future;
      setState(() {
        _imagePixelSize = Size(img.width.toDouble(), img.height.toDouble());
      });
    } catch (e) {
      debugPrint('Failed to read image pixel size: $e');
    }
  }

  Future<void> _captureFromCamera() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final XFile? xfile = await _picker.pickImage(source: ImageSource.camera, imageQuality: 90);
      if (xfile == null) return;
      final file = File(xfile.path);
      setState(() => _imageFile = file);
      await _loadImagePixelSize(file);
      await ImageGallerySaver().saveFile(file.path); // or ImageGallerySaver.saveFile for common plugin
      await _analyzeOnDevice(file);
      await _insertRow(file, _labels);
    } catch (e, st) {
      debugPrint('captureFromCamera error: $e\n$st');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _pickFromGallery() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final XFile? xfile = await _picker.pickImage(source: ImageSource.gallery);
      if (xfile == null) return;
      final file = File(xfile.path);
      setState(() => _imageFile = file);
      await _loadImagePixelSize(file);
      await _analyzeOnDevice(file);
      await _insertRow(file, _labels);
    } catch (e, st) {
      debugPrint('pickFromGallery error: $e\n$st');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _insertRow(File file, List<Map<String, dynamic>> labels) async {
    if (_db == null) return;
    await _db!.insert('photos', {
      'file_path': file.path,
      'taken_at': DateTime.now().millisecondsSinceEpoch,
      'labels_json': jsonEncode(labels),
    });
    setState(() {}); // refresh UI if needed
  }

  // --------------------------- ANALYSIS PIPELINE ---------------------------
  Future<void> _analyzeOnDevice(File imageFile) async {
    try {
      // 1) OCR first
      final texts = await _runTextRecognition(imageFile);
      if (texts.isNotEmpty) {
        setState(() {
          _labels = texts; // only text rows
          _rowPrices.clear();
          _rowSources.clear();
        });
        // Debug: show what OCR captured (helps verify matches like "tesco")
        debugPrint('OCR aggregate: "${_aggregateOcrText()}"');
        return; // short-circuit
      }

      // 2) No text -> object detection (and optional image labeling)
      final objects = await _runObjectDetection(imageFile);
      setState(() {
        _labels = [
          ...objects, // type: 'object', description: <category>, score?: confidence, bbox?: ...
        ];
        _rowPrices.clear();
        _rowSources.clear();
      });
    } catch (e, st) {
      debugPrint('analyzeOnDevice error: $e\n$st');
    }
  }

  Future<List<Map<String, dynamic>>> _runObjectDetection(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final detected = await _objectDetector.processImage(inputImage);
    final results = <Map<String, dynamic>>[];
    for (final obj in detected) {
      String title = 'object';
      double? conf;
      if (obj.labels.isNotEmpty) {
        title = obj.labels.first.text;
        conf = obj.labels.first.confidence;
      }
      results.add({
        'type': 'object',
        'description': title,
        'score': conf,
        'bbox': {
          'left': obj.boundingBox.left,
          'top': obj.boundingBox.top,
          'right': obj.boundingBox.right,
          'bottom': obj.boundingBox.bottom,
        }
      });
    }
    return results;
  }

  Future<List<Map<String, dynamic>>> _runTextRecognition(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final recognizedText = await _textRecognizer.processImage(inputImage);
    final list = <Map<String, dynamic>>[];
    for (final block in recognizedText.blocks) {
      list.add({
        'type': 'text',
        'description': block.text,
        'score': null,
        'bbox': {
          'left': block.boundingBox.left,
          'top': block.boundingBox.top,
          'right': block.boundingBox.right,
          'bottom': block.boundingBox.bottom,
        },
      });
    }
    return list;
  }

  Future<List<Map<String, dynamic>>> _runImageLabeling(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final labels = await _imageLabeler.processImage(inputImage);
    for (final l in labels) {
      debugPrint('ImageLabel: ${l.label} (${l.confidence})');
    }
    return labels
        .map((l) => {
              'type': 'label',
              'description': l.label,
              'score': l.confidence,
            })
        .toList();
  }

  // --------------------------- Helpers ---------------------------
  List<Map<String, dynamic>> _textLabelsOnly() {
    return _labels.where((l) => l['type'] == 'text').toList();
  }

  List<Map<String, dynamic>> _imageLabelsOnly() {
    return _labels.where((l) => l['type'] == 'label').toList();
  }

  bool _hasText() => _labels.any((l) => (l['type'] ?? '') == 'text');

  Widget _tableCell(
    String text, {
    TextStyle? style,
    EdgeInsetsGeometry padding = const EdgeInsets.all(8),
  }) {
    return Padding(
      padding: padding,
      child: SelectableText(
        text.isEmpty ? '-' : text,
        style: style,
        maxLines: null,
        textAlign: TextAlign.start,
      ),
    );
  }

  // --------------------------- Price helpers ---------------------------
  List<String> _extractNumbersFromText() {
    final textItems = _textLabelsOnly();
    final Set<String> ordered = LinkedHashSet<String>();
    final RegExp priceRe = RegExp(
      r'(?:[\£\$\€]\s*)?(?:\d{1,3}(?:[.,]\d{3})+\d+)(?:[.,]\d+)?',
    );
    for (final item in textItems) {
      final raw = (item['description'] ?? '').toString();
      for (final m in priceRe.allMatches(raw)) {
        final val = m.group(0)!.replaceAll(RegExp(r'\s+'), '');
        ordered.add(val);
      }
    }
    return ordered.toList();
  }

  Future<void> _promptForCustomPrice(BuildContext context, int rowIndex) async {
    final controller = TextEditingController(text: _rowPrices[rowIndex] ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Enter price'),
          content: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
            decoration: const InputDecoration(hintText: 'e.g. 2.49 or £2.49'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result != null && result.isNotEmpty) {
      setState(() {
        _rowPrices[rowIndex] = result;
      });
    }
  }

  // --------------------------- Source ranking helpers (NEW) ---------------------------

  /// Aggregate all OCR text from the image into one string.
  /// Useful fallback when a particular row isn't a text row or per-row scores are zero.
  String _aggregateOcrText() {
    return _textLabelsOnly()
        .map((m) => (m['description'] ?? '').toString())
        .join(' ');
  }

  // Normalize text: lowercase, strip common accents/punctuation, collapse spaces.
  String _normalize(String s) {
    final lower = s.toLowerCase();
    final noAccents = lower
        .replaceAll(RegExp(r'[’´`ʼ]'), "'")
        .replaceAll('á', 'a').replaceAll('à', 'a').replaceAll('ä', 'a')
        .replaceAll('é', 'e').replaceAll('è', 'e').replaceAll('ë', 'e')
        .replaceAll('í', 'i').replaceAll('ì', 'i').replaceAll('ï', 'i')
        .replaceAll('ó', 'o').replaceAll('ò', 'o').replaceAll('ö', 'o')
        .replaceAll('ú', 'u').replaceAll('ù', 'u').replaceAll('ü', 'u')
        .replaceAll('ñ', 'n');
    final noPunct = noAccents.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    final collapsed = noPunct.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed;
  }

  Set<String> _tokens(String s) {
    final norm = _normalize(s);
    if (norm.isEmpty) return <String>{};
    return norm.split(' ').where((t) => t.isNotEmpty).toSet();
  }

  /// Score a single shop option against a text. Higher is better.
  int _scoreSourceAgainstText(String option, String rowText) {
    if (option.isEmpty || rowText.isEmpty) return 0;
    final optNorm = _normalize(option);
    final rowNorm = _normalize(rowText);
    final rowTokens = _tokens(rowNorm);
    final optTokens = _tokens(optNorm);

    int score = 0;

    // 1) Exact token matches
    for (final t in optTokens) {
      if (rowTokens.contains(t)) score += 3;
    }

    // 2) Substring match for the whole normalized option
    if (optNorm.isNotEmpty && rowNorm.contains(optNorm)) score += 2;

    // 3) Loose fuzzy: first 4 chars of each option token
    for (final t in optTokens) {
      final stem = t.length >= 4 ? t.substring(0, 4) : t;
      if (stem.isNotEmpty && rowNorm.contains(stem)) score += 1;
    }

    return score;
  }

  /// Return a DEBUG string of scores for logging.
  String _debugScoresForRow(Map<String, dynamic> rowItem, List<String> options, String usedText) {
    final entries = options.map((s) {
      final sc = _scoreSourceAgainstText(s, usedText);
      return '$s:$sc';
    }).join(', ');
    final previewLen = usedText.length.clamp(0, 80);
    final preview = usedText.substring(0, previewLen);
    return '{text:"$preview...", scores: $entries}';
  }

  /// Returns _sourceOptions sorted so that best matches for this row appear first.
  /// If the row isn't text or scores are all zero, fallback to aggregate OCR text.
  List<String> _rankedSourcesForRow(Map<String, dynamic> rowItem, List<String> options) {
    final String rowText = (rowItem['type'] == 'text')
        ? ((rowItem['description'] ?? '').toString())
        : '';

    // First pass: use row-level text if available
    String usedText = rowText;
    var withScores = options.map((s) => MapEntry(s, _scoreSourceAgainstText(s, usedText))).toList();
    final allZero = withScores.every((e) => e.value == 0);

    // Fallback to aggregate OCR text across the image, if needed
    if (allZero) {
      usedText = _aggregateOcrText();
      withScores = options.map((s) => MapEntry(s, _scoreSourceAgainstText(s, usedText))).toList();
    }

    // DEBUG: log the scores so you can verify ranking
    debugPrint('Source ranking row-type=${rowItem['type']} -> ${_debugScoresForRow(rowItem, options, usedText)}');

    // Sort by score desc, then alphabetically asc for determinism.
    withScores.sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      if (cmp != 0) return cmp;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    });

    return withScores.map((e) => e.key).toList();
  }

  // --------------------------- Image + overlays ---------------------------
  Widget _buildPhotoWithOverlays() {
    if (_imageFile == null) return const SizedBox.shrink();
    final textBlocks = _textLabelsOnly().where((t) => t['bbox'] is Map).toList();
    return LayoutBuilder(builder: (context, constraints) {
      final ratio = 1.0;
      final containerWidth = constraints.maxWidth;
      final containerHeight = containerWidth / ratio; // square
      final imgW = (_imagePixelSize?.width ?? 100.0);
      final imgH = (_imagePixelSize?.height ?? 100.0);
      final scale = math.min(containerWidth / imgW, containerHeight / imgH);
      final displayedW = imgW * scale;
      final displayedH = imgH * scale;
      final offsetX = (containerWidth - displayedW) / 2.0;
      final offsetY = (containerHeight - displayedH) / 2.0;

      Rect _mapRect(Map<String, dynamic> bbox) {
        final left = (bbox['left'] as num).toDouble() * scale + offsetX;
        final top = (bbox['top'] as num).toDouble() * scale + offsetY;
        final right = (bbox['right'] as num).toDouble() * scale + offsetX;
        final bottom = (bbox['bottom'] as num).toDouble() * scale + offsetY;
        return Rect.fromLTRB(left, top, right, bottom);
      }

      final overlayChildren = <Widget>[
        Positioned(
          left: offsetX,
          top: offsetY,
          width: displayedW,
          height: displayedH,
          child: Image.file(
            _imageFile!,
            fit: BoxFit.contain, // <-- avoid stretching artifacts
          ),
        ),
        for (final t in textBlocks)
          Builder(builder: (ctx) {
            final bb = Map<String, dynamic>.from(t['bbox'] as Map);
            final rect = _mapRect(bb);
            return Positioned(
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: GestureDetector(
                onTap: () => _onTextBlockTapped(t),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.yellow.withOpacity(0.18),
                    border: Border.all(color: Colors.amber, width: 1.5),
                  ),
                ),
              ),
            );
          }),
      ];

      return SizedBox(
        width: containerWidth,
        height: containerHeight,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: InteractiveViewer(
            clipBehavior: Clip.hardEdge,
            minScale: 1.0,
            maxScale: 4.0,
            child: Stack(children: overlayChildren),
          ),
        ),
      );
    });
  }

  void _onTextBlockTapped(Map<String, dynamic> blockItem) async {
    final raw = (blockItem['description'] ?? '').toString();
    final RegExp priceRe = RegExp(
      r'(?:[\£\$\€]\s*)?(?:\d{1,3}(?:[.,]\d{3})+\d+)(?:[.,]\d+)?',
    );
    final prices = priceRe
        .allMatches(raw)
        .map((m) => m.group(0)!.replaceAll(RegExp(r'\s+'), ''))
        .toList();

    if (prices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No number found in this text block.')),
      );
      return;
    }

    String? chosen;
    if (prices.length == 1) {
      chosen = prices.first;
    } else {
      chosen = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => ListView(
          children: prices.map((p) {
            return ListTile(
              title: Text(p),
              onTap: () => Navigator.pop(ctx, p),
            );
          }).toList(),
        ),
      );
    }
    if (chosen == null) return;

    final int rowIndex = _labels.indexOf(blockItem);
    if (rowIndex >= 0) {
      setState(() {
        _rowPrices[rowIndex] = chosen!;
      });
    }
  }

  // --------------------------- Table ---------------------------
  Widget _buildDynamicResultsTable() {
    const headers = ['ID', 'Brand', 'Item', 'Price', 'Source'];
    const columnWidths = <int, TableColumnWidth>{
      0: FixedColumnWidth(56), // ID
      1: FlexColumnWidth(3),   // Name
      2: FlexColumnWidth(2),   // Type
      3: FixedColumnWidth(140),// Price
      4: FlexColumnWidth(3),   // Source
    };
    const double minWidth = 700.0;

    List<Widget> _buildHeaderCells() {
      return headers
          .map((h) => Padding(
                padding: const EdgeInsets.all(8),
                child: Text(h, style: const TextStyle(fontWeight: FontWeight.bold)),
              ))
          .toList();
    }

    List<Widget> _buildRowCells(int index, Map<String, dynamic> item) {
      final String rawDescription = (item['description'] ?? '').toString().trim();
      final String itemType = (item['type'] ?? '').toString().trim();
      final String name = itemType == 'text' ? rawDescription : '-';
      final String type = itemType == 'object'
          ? (rawDescription.isEmpty ? 'unknown' : rawDescription)
          : itemType;

      // --- PRICE cell ---
      final priceCell = Padding(
        padding: const EdgeInsets.all(8.0),
        child: Builder(builder: (context) {
          final options = _extractNumbersFromText();
          final items = <DropdownMenuItem<String>>[
            const DropdownMenuItem(value: '', child: Text('-')),
            ...options.map((o) => DropdownMenuItem(
                  value: o,
                  child: Text(o, overflow: TextOverflow.ellipsis, maxLines: 1, softWrap: false),
                )),
            const DropdownMenuItem(value: '__custom__', child: Text('Custom…')),
          ];
          final current = _rowPrices[index] ?? '';
          if (current.isNotEmpty && !items.any((it) => it.value == current)) {
            items.insert(
              1,
              DropdownMenuItem(
                value: current,
                child: Text(current, overflow: TextOverflow.ellipsis, maxLines: 1, softWrap: false),
              ),
            );
          }
          return DropdownButtonFormField<String>(
            isExpanded: true,
            value: current.isNotEmpty ? current : '',
            items: items,
            onChanged: (val) async {
              if (val == null) return;
              if (val == '__custom__') {
                await _promptForCustomPrice(context, index);
                setState(() {});
              } else {
                setState(() {
                  _rowPrices[index] = val;
                });
              }
            },
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          );
        }),
      );

      // --- SOURCE cell (ALWAYS interactive; shows banner if loading failed) ---
      final sourceCell = Padding(
        padding: const EdgeInsets.all(8.0),
        child: Builder(builder: (context) {
          // Rank by OCR relevance for THIS row, with fallback to aggregate OCR if needed
          final ranked = _rankedSourcesForRow(item, _sourceOptions);

          final items = <DropdownMenuItem<String>>[
            const DropdownMenuItem(value: '__custom__', child: Text('Custom…')),
            ...ranked.map((s) => DropdownMenuItem(
                  value: s,
                  child: Text(s, overflow: TextOverflow.ellipsis, maxLines: 1, softWrap: false),
                )),
          ];

          final current = _rowSources[index] ?? '';
          // Preserve custom value previously chosen even if it's not in options
          if (current.isNotEmpty && !_sourceOptions.contains(current)) {
            items.insert(
              1,
              DropdownMenuItem(
                value: current,
                child: Text(current, overflow: TextOverflow.ellipsis, maxLines: 1, softWrap: false),
              ),
            );
          }

          // NOTE: We DO NOT disable the dropdown even when _sourceLoadError != null;
          // users can still select Custom… in every row.
          return DropdownButtonFormField<String>(
            isExpanded: true,
            value: current.isNotEmpty ? current : null,
            items: items,
            onChanged: (val) async {
              if (val == null) return;
              if (val == '__custom__') {
                await _promptForCustomSource(context, index);
                setState(() {});
              } else {
                setState(() {
                  _rowSources[index] = val;
                });
              }
            },
            // Hint stays as "Choose source"; load errors are shown as a global banner instead.
            hint: const Text('Choose source'),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          );
        }),
      );

      return <Widget>[
        _tableCell('${index + 1}'), // ID
        _tableCell(name),
        _tableCell(type),
        priceCell,
        sourceCell, // ranked dropdown
      ];
    }

    return FractionallySizedBox(
      widthFactor: 0.95,
      child: Scrollbar(
        controller: _hScrollCtrl,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _hScrollCtrl,
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: minWidth),
            child: Table(
              border: TableBorder.all(color: Colors.black12, width: 1),
              columnWidths: columnWidths,
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                // Header row
                TableRow(
                  decoration: const BoxDecoration(color: Color(0xFFF5F5F5)),
                  children: _buildHeaderCells(),
                ),
                // Data rows
                ...List<TableRow>.generate(_labels.length, (index) {
                  final item = _labels[index];
                  final bool alt = index.isEven;
                  return TableRow(
                    decoration: BoxDecoration(
                      color: alt ? const Color(0xFFFFFFFF) : const Color(0xFFFDFDFD),
                    ),
                    children: _buildRowCells(index, item),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------- Source helpers ---------------------------
  Future<void> _promptForCustomSource(BuildContext context, int rowIndex) async {
    final controller = TextEditingController(text: _rowSources[rowIndex] ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Enter source'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'e.g. Tesco, Amazon, My own'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result != null && result.isNotEmpty) {
      setState(() {
        _rowSources[rowIndex] = result;
      });
    }
  }

  // --------------------------- Category stats (object-detector only) ---------------------------
  Map<String, int> _computeCategoryCountsFromObjectsOnly() {
    final Map<String, int> counts = {};
    for (final item in _labels) {
      if ((item['type'] ?? '') == 'object') {
        final raw = (item['description'] ?? '').toString().trim().toLowerCase();
        final cat = (raw.isEmpty || raw == 'object') ? 'unknown' : raw;
        counts[cat] = (counts[cat] ?? 0) + 1;
      }
    }
    return counts;
  }

  Map<String, double> _computeCategoryPercentagesFromObjectsOnly() {
    final counts = _computeCategoryCountsFromObjectsOnly();
    final int total = counts.values.fold(0, (sum, c) => sum + c);
    final Map<String, double> percentages = {};
    if (total == 0) return percentages;
    counts.forEach((cat, count) {
      percentages[cat] = (count / total) * 100.0;
    });
    return percentages;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Saved photos',
            onPressed: () async {
              if (_db == null) return;
              final rows = await _db!.query('photos', orderBy: 'taken_at DESC');
              if (!mounted) return;
              showModalBottomSheet(
                context: context,
                builder: (_) => ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (ctx, i) {
                    final row = rows[i];
                    final path = row['file_path'] as String;
                    final when = DateTime.fromMillisecondsSinceEpoch(row['taken_at'] as int);
                    final labelsJson = row['labels_json'] as String?;
                    final labels = labelsJson != null ? (jsonDecode(labelsJson) as List) : [];
                    return ListTile(
                      leading: Image.file(
                        File(path),
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      ),
                      title: Text(p.basename(path)),
                      subtitle: Text('${when.toLocal()} • ${labels.length} items'),
                      onTap: () async {
                        Navigator.pop(context);
                        final f = File(path);
                        setState(() {
                          _imageFile = f;
                          _labels = labels
                              .map((l) => Map<String, dynamic>.from(l as Map))
                              .toList();
                          _rowPrices.clear();
                          _rowSources.clear();
                        });
                        await _loadImagePixelSize(f);
                        // Also log OCR aggregate for previously-saved photo
                        debugPrint('OCR aggregate (history): "${_aggregateOcrText()}"');
                      },
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _isBusy ? null : _captureFromCamera,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Camera'),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _isBusy ? null : _pickFromGallery,
                icon: const Icon(Icons.photo_library),
                label: const Text('Pick'),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: 'Reload Source options',
                onPressed: _loadSourceOptions,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_isBusy)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 16),
          // --- Global banner when Source loading fails (keeps dropdowns usable) ---
          if (_sourceLoadError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: MaterialBanner(
                content: Text(_sourceLoadError!),
                leading: const Icon(Icons.error_outline, color: Colors.red),
                actions: [
                  TextButton.icon(
                    onPressed: _loadSourceOptions,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          // --- IMAGE + DETAILS ---
          if (_imageFile != null)
            Expanded(
              child: Column(
                children: [
                  // Photo preview (with tappable overlays)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: AspectRatio(
                      aspectRatio: 1 / 1,
                      child: _buildPhotoWithOverlays(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Scrollable details (consistent Table)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            const Text(
                              'Detection Results',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            if (_labels.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6.0),
                                child: Text('No items found.'),
                              )
                            else
                              _buildDynamicResultsTable(),
                            const SizedBox(height: 16),
                            // Category Stats (Object Detector)
                            if (!_hasText()) ...[
                              const Text(
                                'Category Stats (Object Detector)',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              Builder(builder: (context) {
                                final counts = _computeCategoryCountsFromObjectsOnly();
                                if (counts.isEmpty) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 6.0),
                                    child: Text('No categories detected.'),
                                  );
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: counts.entries.map((e) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                                      child: Text('${e.key}: ${e.value} item(s)'),
                                    );
                                  }).toList(),
                                );
                              }),
                              const SizedBox(height: 8),
                              Builder(builder: (context) {
                                final percentages = _computeCategoryPercentagesFromObjectsOnly();
                                if (percentages.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: percentages.entries.map((e) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                                      child: Text('${e.key}: ${e.value.toStringAsFixed(1)}%'),
                                    );
                                  }).toList(),
                                );
                              }),
                            ],
                            const SizedBox(height: 16),
                            // OCR text section
                            const Text(
                              'Text found',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            if (_textLabelsOnly().isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6.0),
                                child: Text('No text found in this image.'),
                              )
                            else
                              ..._textLabelsOnly().map((l) {
                                final String line = (l['description'] ?? '').toString();
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                                  child: Text(line, style: const TextStyle(fontSize: 16)),
                                );
                              }).toList(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(24.0),
              child: Text('No photo yet — tap Camera or Pick.'),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isBusy ? null : _captureFromCamera,
        tooltip: 'Take Photo',
        child: const Icon(Icons.camera),
      ),
    );
  }
}
