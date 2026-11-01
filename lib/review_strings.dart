import 'package:flutter/material.dart';
import 'exclusions.dart';

String reviewText(BuildContext context, String ar, String en) =>
    Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

String dispositionLabel(BuildContext context, TxDisposition value) =>
    switch (value) {
      TxDisposition.active =>
        reviewText(context, 'تحتاج مراجعة', 'Needs review'),
      TxDisposition.deferred => reviewText(context, 'مؤجلة', 'Deferred'),
      TxDisposition.ignored =>
        reviewText(context, 'ليست معاملة', 'Not a transaction'),
      TxDisposition.duplicate =>
        reviewText(context, 'محسوبة سابقًا', 'Already recorded'),
    };
