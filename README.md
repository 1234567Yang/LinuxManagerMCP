<div align="center">

<h1>Linux Manager MCP</h1>

[中文](README_zh.md) · English

<br>
</div>


> [!CAUTION]
> This is a for-fun project. Do not use it in production, and do not use it on any machine you
> care about — you are on your own if you do. No security guarantees are made.<br>
> Related /【合订本】a collection of AI-wiped-my-server incidents seen on the forum (login
> required): https://linux.do/t/topic/1585027
---

## Introduction

Give your LLM access to your Linux server and let it drive. Unlike OpenClaw, this is an MCP
plugin: it needs no API key, and for now it has no memory either.

## Demo

English:
[Demo](demo.md)

中文：
[用法示例](demo_zh.md)

## Features

* Multiple shell windows, with background execution.
  * When you ask an LLM to install a dependency, a conventional MCP will just keep running until
    the command finishes or the timeout kills it.
  * This project lets the LLM open several shell windows, set its own foreground wait time and
    hard kill time, and pull the output so far at any moment to see how things are going.
* Every shell window has a notes area.
  * So the LLM can remind itself why a window was opened and what has been done in it.
* Sudo separation, no sudo privileges by default.
  * Shell sessions handed to the LLM are non-sudo; it has to explicitly ask for sudo to get it.
  * Sudo can be turned off entirely in the program.

## TODO

Ctrl+C to interrupt a command (instead of killing the whole shell), finer-grained controls, a
logging system, several people controlling the same machine.

## Misc

Calling out A/'s damn Cybersecurity filter here: apparently driving a Linux box automatically
counts as a security matter, so it cut me off halfway through and demanded I switch to Sunnet
4.6. Pure aggravation.
