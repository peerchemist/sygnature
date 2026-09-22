import 'package:flutter/material.dart';

import '../app_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.compact = false, this.light = false});

  final bool compact;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final foreground = light ? Colors.white : AppColors.ink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: light ? Colors.white : AppColors.forest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            Icons.account_balance_wallet_outlined,
            size: 18,
            color: light ? AppColors.forest : Colors.white,
          ),
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
