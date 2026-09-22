import 'package:flutter/material.dart';

void main() {
  runApp(const SygnatureBootstrap());
}

class SygnatureBootstrap extends StatelessWidget {
  const SygnatureBootstrap({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Sygnature',
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: Text('Sygnature'))),
    );
  }
}
