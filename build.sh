#!/bin/bash
set -e

echo "Building mini-vz..."

swiftc -O -framework Virtualization -framework AppKit -o mini-vz main.swift
codesign --force --sign - --entitlements entitlements.plist mini-vz

echo "Copying executable to ~/.local/bin"

mkdir -p ~/.local/bin
cp mini-vz ~/.local/bin/

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo "Done! Add ~/.local/bin to your PATH to run mini-vz from anywhere:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
    echo "Add that line to your ~/.zshrc or ~/.bashrc to make it permanent."
else
    echo "Done! mini-vz installed to ~/.local/bin"
fi
