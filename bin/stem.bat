@echo off

:: SPDX-License-Identifier: Apache-2.0
:: SPDX-FileCopyrightText: 2021 The Elixir Team
:: SPDX-FileCopyrightText: 2012 Plataformatec

set "EXBAR_CWD=%CD%"
cd /d "%~dp0\..\lib\stem" && call "%~dp0\mix.bat" stem %*
