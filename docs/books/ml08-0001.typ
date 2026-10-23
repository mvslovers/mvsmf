#import "bookmaster/bookmaster.typ": *

#show: book.with(
  title: "mvsMF for MVS 3.8j",
  subtitle: "User's Guide",
  short-title: "mvsMF User's Guide",
  product: "mvsMF",
  number: "ML08-0001-0",
  date: "October 2026",
  authors: ("Mike Großmann",),
  edition: [
    #text(font: head-font, weight: "bold", size: 11pt)[Draft Edition (October 2026)]

    This edition applies to Version 1 Release 4 of mvsMF, the z/OSMF REST API
    for MVS 3.8j (mvsmf 1.4.0), and to all subsequent releases and
    modifications until otherwise indicated in new editions.

    *Draft.* This book is a draft edition.

    Comments on this book may be addressed to the issue tracker of the
    mvslovers/mvsmf repository on GitHub.

    © Copyright Mike Großmann 2026. All rights reserved.
  ],
)

#part("index.html", title: [mvsMF User's Guide])[
#titlepage()
#contents()
#figures()

#heading(numbering: none)[About This Book] <about>

This book shows how to use mvsMF (mvsmf), the z/OSMF REST API for MVS 3.8j,
with the command line client curl. It is organized by tasks: logging in,
working with data sets and their members, working with files in UFS,
submitting a job and reading its output, issuing a console command, and finding
what a typical error means. Each task has a session that was typed at a real
mvsMF, so the reader sees what to type and what comes back. The chapters for
the administrator are tasks as well: setting up security, installing mvsMF,
running it and removing it again. Every endpoint, parameter, header, field,
status code and message in full is the subject of the companion volume, the
_mvsMF Reference_.

The book describes mvsMF 1.4: how to use it, how to install it, upgrade it and
take it off a system again, and how to run it. mvsMF is a clone of the REST
interface of IBM's z/OSMF. It is not z/OSMF.

== How This Book Is Organized

#deflist(width: 1.35in,
  [Chapter 1], [“Introducing mvsMF”.],
  [Chapter 2], [“Connecting and Logging In”.],
  [Chapter 3], [“Working with Data Sets”.],
  [Chapter 4], [“Working with Files in UFS”.],
  [Chapter 5], [“Submitting Jobs and Reading Their Output”.],
  [Chapter 6], [“Issuing Console Commands”.],
  [Chapter 7], [“Typical Errors and What They Mean”.],
  [Chapter 8], [“Setting Up Security”.],
  [Chapter 9], [“Installing mvsMF”.],
  [Chapter 10], [“Running mvsMF”.],
  [Chapter 11], [“Removing mvsMF”.],
  [Appendix A], [“Glossary”.],
)

== Related Publications

#deflist(width: 1.35in,
  [ML08-0002], [_mvsMF Reference_: the services, parameters, headers, status
    codes and error reports of mvsMF, the HTTPD configuration it needs, the
    diagnostic endpoint and the messages of mvsMF.],
)

#mainmatter()
]
#set page(numbering: "1")

#part("ug-intro.html", include "guide/ug-intro.typ")
#part("ug-first.html", include "guide/ug-first.typ")
#part("ug-data.html", include "guide/ug-data.typ")
#part("ug-uss.html", include "guide/ug-uss.typ")
#part("ug-jobs.html", include "guide/ug-jobs.typ")
#part("ug-console.html", include "guide/ug-console.typ")
#part("ug-errors.html", include "guide/ug-errors.typ")
#part("ug-security.html", include "guide/ug-security.typ")
#part("ug-install.html", include "guide/ug-install.typ")
#part("ug-ops.html", include "guide/ug-ops.typ")
#part("ug-remove.html", include "guide/ug-remove.typ")

#show: appendices
#part("ug-glossary.html", include "guide/ug-glossary.typ")

#part("index-terms.html", title: [Index])[
#heading(numbering: none)[Index]
#make-index()
]
