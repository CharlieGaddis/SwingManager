# TOS Automation

This folder contains durable Thinkorswim automation knowledge for Swing Manager. The goal is to stop relying on chat memory and promote only verified recipes into production.

## Architecture

- `Discovery/`: read-only snapshots, captures, and reverse-engineering artifacts.
- `Locators/`: approved semantic locators. These are data, not code guesses.
- `Recipes/`: step-by-step automation transactions with preconditions and postconditions.
- `Diagnostics/`: diffs, failure captures, and troubleshooting output.
- `Production/`: scripts/config promoted after repeatable successful test cycles.

## Operating Rule

Java Access Bridge is the state sensor. Native Win32 input is the hand. After every TOS UI change, discard prior JAB references, rediscover, and verify the expected state before continuing.

## Promotion Standard

A TOS recipe is not production-ready until it has:

1. A screen-state fingerprint.
2. A saved accessibility snapshot.
3. A screenshot or crop.
4. A semantic locator definition.
5. A recipe with explicit preconditions and postconditions.
6. A repeatability log.
7. A source-control commit.

The target for OCO updates is 25 consecutive successful cycles across TOS restart, window movement, row movement, and accordion open/closed states.
