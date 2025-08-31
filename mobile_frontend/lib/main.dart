import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// PUBLIC_INTERFACE
void main() {
  /** App entrypoint: sets up Provider state management and launches themed MaterialApp. */
  runApp(const SmartCalcApp());
}

/// Application colors based on provided palette.
class AppColors {
  static const Color primary = Color(0xFF1976D2); // #1976D2
  static const Color secondary = Color(0xFF42A5F5); // #42A5F5
  static const Color accent = Color(0xFFFF4081); // #FF4081
  static const Color surface = Color(0xFFF7F9FC);
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textMuted = Color(0xFF475569);
}

/// Calculator history item model.
class HistoryItem {
  final String expression;
  final String result;
  final DateTime timestamp;

  HistoryItem({
    required this.expression,
    required this.result,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'expression': expression,
        'result': result,
        'timestamp': timestamp.toIso8601String(),
      };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
        expression: json['expression'] as String,
        result: json['result'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

/// Calculator state and logic provider.
class CalculatorProvider extends ChangeNotifier {
  static const _prefsHistoryKey = 'calc_history_v1';

  String _display = '0';
  String _expression = '';
  String _lastResult = '';
  bool _justEvaluated = false;
  final List<HistoryItem> _history = [];

  String get display => _display;
  String get expression => _expression;
  List<HistoryItem> get history => List.unmodifiable(_history);

  CalculatorProvider() {
    _loadHistory();
  }

  /// Append a digit or dot to the current display.
  void inputDigit(String digit) {
    if (_justEvaluated) {
      // Start a new expression after equals pressed
      _expression = '';
      _display = '0';
      _justEvaluated = false;
    }
    if (digit == '.' && _display.contains('.')) return;

    if (_display == '0' && digit != '.') {
      _display = digit;
    } else {
      _display += digit;
    }
    notifyListeners();
  }

  /// Append an operator to the expression.
  void inputOperator(String operator) {
    // After evaluation, continue with result
    if (_justEvaluated) {
      _expression = _lastResult;
      _justEvaluated = false;
    } else {
      // If display has number, push it into expression
      if (_display.isNotEmpty) {
        _expression += _display;
      }
    }
    // Avoid double operators, replace the last if needed
    if (_expression.isNotEmpty &&
        _isOperator(_expression.characters.last)) {
      _expression = _expression.substring(0, _expression.length - 1) + operator;
    } else {
      _expression += operator;
    }
    _display = '';
    notifyListeners();
  }

  /// Apply a scientific function to the current display value.
  void applyFunction(String fn) {
    // scientific functions operate on the current number
    final val = double.tryParse(_display.isEmpty ? '0' : _display) ?? 0.0;
    double result;
    switch (fn) {
      case 'sin':
        result = math.sin(_toRadians(val));
        break;
      case 'cos':
        result = math.cos(_toRadians(val));
        break;
      case 'tan':
        result = math.tan(_toRadians(val));
        break;
      case 'log':
        // log base 10, handle non-positive values
        if (val <= 0) {
          _display = 'Error';
          _justEvaluated = true;
          notifyListeners();
          return;
        }
        result = math.log(val) / math.ln10;
        break;
      case '√':
        if (val < 0) {
          _display = 'Error';
          _justEvaluated = true;
          notifyListeners();
          return;
        }
        result = math.sqrt(val);
        break;
      default:
        return;
    }
    _display = _formatNumber(result);
    _justEvaluated = true;
    notifyListeners();
  }

  /// Clear all (AC).
  void clearAll() {
    _display = '0';
    _expression = '';
    _justEvaluated = false;
    notifyListeners();
  }

  /// Backspace one character from display.
  void backspace() {
    if (_justEvaluated) {
      // After evaluation, backspace resets to 0
      _display = '0';
      _justEvaluated = false;
      notifyListeners();
      return;
    }
    if (_display.isEmpty || _display == '0') return;
    _display = _display.substring(0, _display.length - 1);
    if (_display.isEmpty) _display = '0';
    notifyListeners();
  }

  /// Compute the result using a safe evaluator.
  void evaluate() {
    // Build final expression with current display
    var expr = _expression;
    if (_display.isNotEmpty) {
      expr += _display;
    }
    if (expr.isEmpty) return;

    try {
      final value = _evaluateExpression(expr);
      final resultStr = _formatNumber(value);
      _lastResult = resultStr;

      // Update display and history
      _display = resultStr;
      _expression = '';
      _justEvaluated = true;

      final item = HistoryItem(
        expression: expr,
        result: resultStr,
        timestamp: DateTime.now(),
      );
      _history.insert(0, item);
      _persistHistory();

      notifyListeners();
    } catch (_) {
      _display = 'Error';
      _expression = '';
      _justEvaluated = true;
      notifyListeners();
    }
  }

  /// Copy current display to clipboard.
  Future<void> copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _display));
  }

  bool _isOperator(String char) {
    return char == '+' || char == '-' || char == '×' || char == '÷' || char == '*' || char == '/';
  }

  // A small expression evaluator for +,-,*,/ and decimals.
  // This avoids bringing in heavy math parsers and keeps it offline.
  double _evaluateExpression(String expression) {
    // Normalize operators
    String expr = expression.replaceAll('×', '*').replaceAll('÷', '/');
    // Tokenize
    final tokens = _tokenize(expr);
    // Shunting-yard to RPN
    final rpn = _toRPN(tokens);
    // Evaluate RPN
    return _evalRPN(rpn);
    // Note: For simplicity this doesn't handle parentheses.
  }

  List<String> _tokenize(String s) {
    final List<String> tokens = [];
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      if ('0123456789.'.contains(ch)) {
        buffer.write(ch);
      } else if (_isOperator(ch)) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        tokens.add(ch);
      } else if (ch.trim().isEmpty) {
        // skip spaces
      } else {
        throw FormatException('Invalid character');
      }
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }

  int _prec(String op) {
    switch (op) {
      case '+':
      case '-':
        return 1;
      case '*':
      case '/':
        return 2;
      default:
        return 0;
    }
  }

  List<String> _toRPN(List<String> tokens) {
    final List<String> output = [];
    final List<String> ops = [];
    for (final t in tokens) {
      if (double.tryParse(t) != null) {
        output.add(t);
      } else if (_isOperator(t)) {
        while (ops.isNotEmpty && _prec(ops.last) >= _prec(t)) {
          output.add(ops.removeLast());
        }
        ops.add(t);
      } else {
        throw FormatException('Invalid token');
      }
    }
    while (ops.isNotEmpty) {
      output.add(ops.removeLast());
    }
    return output;
  }

  double _evalRPN(List<String> rpn) {
    final List<double> stack = [];
    for (final t in rpn) {
      final numVal = double.tryParse(t);
      if (numVal != null) {
        stack.add(numVal);
      } else {
        if (stack.length < 2) throw FormatException('Malformed expression');
        final b = stack.removeLast();
        final a = stack.removeLast();
        switch (t) {
          case '+':
            stack.add(a + b);
            break;
          case '-':
            stack.add(a - b);
            break;
          case '*':
            stack.add(a * b);
            break;
          case '/':
            if (b == 0) throw FormatException('Division by zero');
            stack.add(a / b);
            break;
          default:
            throw FormatException('Unknown operator');
        }
      }
    }
    if (stack.length != 1) throw FormatException('Malformed expression');
    return stack.single;
  }

  String _formatNumber(double value) {
    // Trim trailing zeros for cleaner display
    String s = value.toStringAsFixed(10);
    s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s;
  }

  double _toRadians(double degrees) => degrees * math.pi / 180.0;

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsHistoryKey);
    if (raw == null) return;
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      _history
        ..clear()
        ..addAll(list.map((e) => HistoryItem.fromJson(e as Map<String, dynamic>)));
      notifyListeners();
    } catch (_) {
      // ignore corrupted history
    }
  }

  Future<void> _persistHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_history.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsHistoryKey, encoded);
  }

  /// Reuse a history entry (tap to load its result).
  void reuseHistoryResult(HistoryItem item) {
    _display = item.result;
    _expression = '';
    _justEvaluated = true;
    notifyListeners();
  }
}

/// App root with theming and Provider.
class SmartCalcApp extends StatelessWidget {
  const SmartCalcApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        surface: AppColors.surface,
      ),
      scaffoldBackgroundColor: AppColors.surface,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.textPrimary),
      ),
    );

    return ChangeNotifierProvider(
      create: (_) => CalculatorProvider(),
      child: MaterialApp(
        title: 'SmartCalc',
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            elevation: 0,
            foregroundColor: AppColors.textPrimary,
          ),
        ),
        home: const CalculatorScreen(),
      ),
    );
  }
}

/// Calculator screen with responsive/adaptive layout.
class CalculatorScreen extends StatelessWidget {
  const CalculatorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: _ResponsiveLayout(),
      ),
    );
  }
}

/// Responsive layout that adapts between portrait and landscape.
class _ResponsiveLayout extends StatelessWidget {
  const _ResponsiveLayout();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isLandscape = media.orientation == Orientation.landscape;

    // Common panels
    final display = const _DisplayPanel();
    final keypad = const _KeypadPanel();
    final history = const _HistoryPanel();

    if (isLandscape) {
      // Side-by-side with resizable feel using flex
      return Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              children: [
                display,
                const SizedBox(height: 8),
                Expanded(child: keypad),
              ],
            ),
          ),
          Container(
            width: 1,
            color: Colors.black.withAlpha(12),
          ),
          Expanded(
            flex: 2,
            child: history,
          ),
        ],
      );
    }

    // Portrait: display + keypad; history as bottom persistent panel
    return Column(
      children: [
        display,
        const SizedBox(height: 8),
        Expanded(child: keypad),
        Container(
          height: media.size.height * 0.24,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              top: BorderSide(color: Colors.black.withAlpha(12), width: 1),
            ),
          ),
          child: history,
        ),
      ],
    );
  }
}

/// Display panel with expression, result, and actions (copy/clear/backspace).
class _DisplayPanel extends StatelessWidget {
  const _DisplayPanel();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CalculatorProvider>();
    final expression = provider.expression;
    final display = provider.display;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top actions row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'SmartCalc',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
              Row(
                children: [
                  _IconActionButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy',
                    color: AppColors.secondary,
                    onTap: () {
                      // Perform copy asynchronously in provider; UI feedback scheduled synchronously here.
                      context.read<CalculatorProvider>().copyToClipboard();
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        messenger?.showSnackBar(
                          const SnackBar(
                            content: Text('Copied to clipboard'),
                            duration: Duration(milliseconds: 800),
                          ),
                        );
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  _IconActionButton(
                    icon: Icons.backspace_rounded,
                    tooltip: 'Backspace',
                    color: AppColors.primary,
                    onTap: () => context.read<CalculatorProvider>().backspace(),
                  ),
                  const SizedBox(width: 8),
                  _IconActionButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Clear',
                    color: AppColors.accent,
                    onTap: () => context.read<CalculatorProvider>().clearAll(),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Expression (small, scrollable horizontally if long)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Text(
              expression,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Main display (result / current input)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Text(
              display,
              textAlign: TextAlign.right,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 42,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon action button with minimal style.
class _IconActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _IconActionButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            border: Border.all(color: color.withAlpha(40)),
            color: color.withAlpha(16),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

/// Keypad panel with numbers, operators, scientific functions, equals.
class _KeypadPanel extends StatelessWidget {
  const _KeypadPanel();

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 420;

    // Define keys
    final List<_KeySpec> topRow = [
      _KeySpec(label: 'sin', type: _KeyType.function),
      _KeySpec(label: 'cos', type: _KeyType.function),
      _KeySpec(label: 'tan', type: _KeyType.function),
      _KeySpec(label: 'log', type: _KeyType.function),
      _KeySpec(label: '√', type: _KeyType.function),
    ];

    final List<_KeySpec> mainKeys = [
      _KeySpec(label: '7'),
      _KeySpec(label: '8'),
      _KeySpec(label: '9'),
      _KeySpec(label: '÷', type: _KeyType.operator, color: AppColors.primary),
      _KeySpec(label: '4'),
      _KeySpec(label: '5'),
      _KeySpec(label: '6'),
      _KeySpec(label: '×', type: _KeyType.operator, color: AppColors.primary),
      _KeySpec(label: '1'),
      _KeySpec(label: '2'),
      _KeySpec(label: '3'),
      _KeySpec(label: '-', type: _KeyType.operator, color: AppColors.primary),
      _KeySpec(label: '0', flex: 2),
      _KeySpec(label: '.', type: _KeyType.digit),
      _KeySpec(label: '+', type: _KeyType.operator, color: AppColors.primary),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          // Scientific functions row (scroll on small widths)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: topRow
                  .map((k) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: _CalcButton(spec: k, large: isWide),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 8),
          // Main grid
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Use rows with wrap-style layout for flexibility
                final double spacing = 8;
                final children = <Widget>[];
                for (int i = 0; i < mainKeys.length; i += 4) {
                  final rowKeys = mainKeys.sublist(i, math.min(i + 4, mainKeys.length));
                  children.add(
                    Row(
                      children: rowKeys
                          .map(
                            (k) => Expanded(
                              flex: k.flex,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: k == rowKeys.first ? 0 : spacing / 2,
                                  right: k == rowKeys.last ? 0 : spacing / 2,
                                  bottom: spacing,
                                ),
                                child: _CalcButton(spec: k, large: isWide),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  );
                }
                // Equals row
                children.add(
                  Row(
                    children: [
                      Expanded(
                        child: _CalcButton(
                          spec: _KeySpec(
                            label: '=',
                            type: _KeyType.equals,
                            color: AppColors.accent,
                          ),
                          large: isWide,
                          tall: true,
                        ),
                      ),
                    ],
                  ),
                );

                return Column(children: children);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// History panel with persistent list and tap-to-reuse.
class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel();

  @override
  Widget build(BuildContext context) {
    final history = context.watch<CalculatorProvider>().history;

    if (history.isEmpty) {
      return const Center(
        child: Text(
          'No history yet',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: history.length,
      separatorBuilder: (_, __) => Divider(
        color: Colors.black.withAlpha(12),
        height: 12,
      ),
      itemBuilder: (context, index) {
        final item = history[index];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.read<CalculatorProvider>().reuseHistoryResult(item),
          child: Ink(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.black.withAlpha(12)),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.secondary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.expression,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.result,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.north_west_rounded, color: Colors.black.withAlpha(100), size: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Button specification.
class _KeySpec {
  final String label;
  final _KeyType type;
  final Color? color;
  final int flex;

  _KeySpec({
    required this.label,
    this.type = _KeyType.digit,
    this.color,
    this.flex = 1,
  });
}

enum _KeyType { digit, operator, function, equals }

/// Calculator key button with modern minimal styling.
class _CalcButton extends StatelessWidget {
  final _KeySpec spec;
  final bool large;
  final bool tall;

  const _CalcButton({
    required this.spec,
    this.large = false,
    this.tall = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color borderColor = (spec.color ?? AppColors.textMuted).withAlpha(36);
    final Color fillColor =
        (spec.type == _KeyType.equals) ? AppColors.accent.withAlpha(32) : (spec.color ?? AppColors.secondary).withAlpha(16);
    final Color textColor =
        (spec.type == _KeyType.equals) ? AppColors.accent : (spec.color ?? AppColors.textPrimary);

    final double height = tall ? 56 : 52;
    final double fontSize = large ? 20 : 18;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _handleTap(context),
      child: Ink(
        height: height,
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Center(
          child: Text(
            spec.label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: textColor,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context) {
    final calc = context.read<CalculatorProvider>();
    switch (spec.type) {
      case _KeyType.digit:
        calc.inputDigit(spec.label);
        break;
      case _KeyType.operator:
        calc.inputOperator(spec.label);
        break;
      case _KeyType.function:
        calc.applyFunction(spec.label);
        break;
      case _KeyType.equals:
        calc.evaluate();
        break;
    }
  }
}
