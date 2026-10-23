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

ABOUT

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
