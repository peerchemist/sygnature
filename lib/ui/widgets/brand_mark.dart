import 'package:flutter/material.dart';

import '../app_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.compact = false, this.light = false});

  final bool compact;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final foreground = light ? Colors.white : AppColors.of(context).ink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/branding/app-icon.png',
          width: 32,
          height: 32,
          semanticLabel: 'Sygnature',
        ),
        if (!compact) ...[
          const SizedBox(width: 11),
          Text(
            'SYGNATURE',
            style: TextStyle(
              color: foreground,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ],
    );
  }
}
