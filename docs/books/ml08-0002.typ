#import "bookmaster/bookmaster.typ": *

#show: book.with(
  title: "mvsMF for MVS 3.8j",
  subtitle: "Reference",
  short-title: "mvsMF Reference",
  product: "mvsMF",
  number: "ML08-0002-0",
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

#part("index.html", title: [mvsMF Reference])[
#titlepage()
#contents()
#figures()

#heading(numbering: none)[About This Book] <about>

ABOUT

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
