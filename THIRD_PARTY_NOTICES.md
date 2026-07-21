# Third-Party Notices

BoardKit depends on [ChessCore](https://github.com/fianchettochess/ChessCore),
which is distributed under the MIT License:

> Copyright (c) 2026 Jared Brewer

The following MIT-licensed sources materially informed adapter implementations,
as recorded in their checked-in source annotations. Their copyright statements
are preserved here:

- [NSStudent/EasyLinkSwiftSDK](https://github.com/NSStudent/EasyLinkSwiftSDK),
  revision `1b9710593b192ae102f8a1fd695467c9eb990535` —
  Copyright (c) 2026 Omar
- [chessnutech/EasyLinkSDK](https://github.com/chessnutech/EasyLinkSDK),
  revision `4554d17be976f746b8b1139a3b9a025e2b54c8ba` —
  Copyright (c) 2022 chessnutech
- [mono424/certabodriver](https://github.com/mono424/certabodriver),
  revision `d61997c60b623c221d0ffb0dd527e8857aedfbbb` —
  Copyright (c) 2021 Khadim Fall
- [mono424/chessupdriver](https://github.com/mono424/chessupdriver), revision
  `589d43ad2b5eb32b1bcdcca9db2b4909efe5d9bb` — Copyright (c) 2022 Khadim Fall
- [mono424/dgtdriver](https://github.com/mono424/dgtdriver), license and source
  reviewed at revision `333b1d6b151368168a395c43364cc27798920bfc` —
  Copyright (c) 2021 Khadim Fall
- [domschl/python-mchess](https://github.com/domschl/python-mchess), license and
  source reviewed at revision `74ccfd406f4fb99e85891a42f27213d7d796f671`
  — Copyright (c) 2018 Dominik Schlösser
- [alstrup/chesslink](https://github.com/alstrup/chesslink), license and source
  reviewed at revision `13b642733d7a4d11ed7dd98dce20a2aae7c820d2`
  — Copyright (c) 2021 Asger Alstrup Palm

The MIT License text applicable to those notices follows:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

When distributing BoardKit source or compiled binaries that include the
corresponding adapted material, include this file or otherwise reproduce the
copyright notices and MIT permission text above in the distribution.

## Pegasus developer-key provenance

BoardKit's default Pegasus developer-key value is published by at least two
pinned public community implementations:

- [mono424/dgtdriver at `333b1d6b`](https://github.com/mono424/dgtdriver/blob/333b1d6b151368168a395c43364cc27798920bfc/lib/DGTBoard.dart)
  (MIT; notice reproduced above)
- [EdNekebno/PegasusChessComChromeExtension at `5fe10bdc`](https://github.com/EdNekebno/PegasusChessComChromeExtension/blob/5fe10bdcf00827886d1ad8702278abe65680a2ee/content_script.js)
  (GPL-3.0; protocol-behavior reference only)

These sources establish public duplication of the value; they do not establish
that DGT officially authorizes its general reuse. No
source file from the GPL-licensed extension is redistributed by BoardKit.

## Documentation tooling

[Swift-DocC Plugin](https://github.com/swiftlang/swift-docc-plugin) is an
independent, build-time documentation dependency licensed under the Apache
License 2.0. It is not linked into BoardKit library products; its upstream
license and notices apply separately.

Other protocol references, including GPL-licensed, proprietary, and unlicensed
sources, are identified in the README and individual adapter source headers.
They were used for protocol research and behavior comparison. No third-party
source files or fixture blobs from those references are redistributed in this
package. Their licenses apply independently; this notice does not relicense
third-party work.

BoardKit is an independent project and is not affiliated with or endorsed by
the board manufacturers or driver authors named in its compatibility and
provenance documentation. Product names and trademarks belong to their
respective owners and are used only to identify compatibility.
