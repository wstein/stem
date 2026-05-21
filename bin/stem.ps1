# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

$env:EXBAR_CWD = (Get-Location).Path
Set-Location (Join-Path $PSScriptRoot "..")
mix stem @args
