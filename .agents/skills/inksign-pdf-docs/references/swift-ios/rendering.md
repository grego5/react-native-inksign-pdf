# iOS rendering

PDFKit and Quartz provide base page imagery. A transparent native overlay presents
committed and in-progress PencilKit content. Completed drawings enter page history;
live strokes and predictions remain transient.

Page-turn previews compose the target PDF page with committed ink and text.
CoreText shapes committed text. Rendering results update presentation for the
current document and page request. Text and ink use canonical top-left page
coordinates across viewport zoom and display scale.
