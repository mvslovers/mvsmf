#import "bookmaster/bookmaster.typ": *

#show: book.with(
  title: "mvsMF for MVS 3.8j",
  subtitle: "Reference",
  short-title: "mvsMF Reference",
  product: "mvsMF",
  number: "ML08-0002-1",
  date: "October 2026",
  authors: ("Mike Großmann",),
  edition: [
    #text(font: head-font, weight: "bold", size: 11pt)[First Edition (October 2026)]

    This edition applies to Version 1 Release 4 of mvsMF, the z/OSMF REST API
    for MVS 3.8j (mvsmf 1.4.0), and to all subsequent releases and
    modifications until otherwise indicated in new editions.

    Comments on this book may be addressed to the issue tracker of the
    mvslovers/mvsmf repository on GitHub.

    © Copyright Mike Großmann 2026. All rights reserved.
  ],
)

#part("index.html", title: [mvsMF Reference])[
#titlepage()
#contents()
#figures()

#heading(numbering: none)[About This Book] <about>

This book is the reference for mvsMF (mvsmf), the z/OSMF REST API for MVS
3.8j. It lists every service of mvsMF with its method and path, its query
parameters, request headers and body fields, the fields of the answer, the
status codes and the error report. It also lists the HTTPD configuration that
mvsMF needs, the diagnostic endpoint and the messages. It does not teach: the
tasks, with sessions typed at a real mvsMF, are the subject of the companion
volume, the _mvsMF User's Guide_.

The book describes mvsMF 1.4. mvsMF is a clone of the REST interface of IBM's
z/OSMF. It is not z/OSMF, and where it differs the text says so.

== How This Book Is Organized

#deflist(width: 1.35in,
  [Chapter 1], [“Conventions”.],
  [Chapter 2], [“Authentication and System Information”.],
  [Chapter 3], [“Data Set Services”.],
  [Chapter 4], [“File Services”.],
  [Chapter 5], [“Job Services”.],
  [Chapter 6], [“Console Services”.],
  [Chapter 7], [“Configuring HTTPD for mvsMF”.],
  [Chapter 8], [“The Diagnostic Endpoint”.],
  [Appendix A], [“Messages”.],
)

== Related Publications

#deflist(width: 1.35in,
  [ML08-0001], [_mvsMF User's Guide_: the tasks, with sessions, and the
    chapters on security, installation, operation and removal.],
)

#mainmatter()
]
#set page(numbering: "1")

#part("ref-conv.html", include "ref/ref-conv.typ")
#part("ref-auth.html", include "ref/ref-auth.typ")
#part("ref-ds.html", include "ref/ref-ds.typ")
#part("ref-uss.html", include "ref/ref-uss.typ")
#part("ref-jobs.html", include "ref/ref-jobs.typ")
#part("ref-cons.html", include "ref/ref-cons.typ")
#part("ref-httpd.html", include "ref/ref-httpd.typ")
#part("ref-test.html", include "ref/ref-test.typ")

#show: appendices
#part("apx-messages.html", include "ref/apx-messages.typ")

#part("index-terms.html", title: [Index])[
#heading(numbering: none)[Index]
#make-index()
]
