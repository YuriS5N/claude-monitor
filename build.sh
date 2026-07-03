#!/bin/bash
# Compila o Claude Monitor
set -e
cd "$(dirname "$0")"

echo "Compilando Claude Monitor..."

# Shim ObjC para capturar NSException (CoreText pode lançar exceções intermitentes)
clang -c -O2 -o /tmp/claude-monitor-exceptioncatcher.o Sources/ExceptionCatcher.m

swiftc -parse-as-library -framework SwiftUI -framework AppKit -O \
    -import-objc-header Sources/ExceptionCatcher.h \
    -o ClaudeMonitor Sources/ClaudeMonitor.swift /tmp/claude-monitor-exceptioncatcher.o

echo "Build concluido: ./ClaudeMonitor"
echo "Para iniciar: ./start.sh"
