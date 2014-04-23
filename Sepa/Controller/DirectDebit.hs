{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeSynonymInstances      #-}

module Sepa.Controller.DirectDebit where

import           Control.Lens                   hiding (element, elements,
                                                 index, set, view)
import           Control.Monad
import           Data.List                      (groupBy)
import           Data.Maybe
import qualified Data.Text                      as T (Text, pack, unpack)
import qualified Data.Time.Calendar             as C
import qualified Data.Time.LocalTime            as C
import qualified Database.Persist
import qualified Database.Persist.MongoDB       as DB
import           Graphics.UI.Gtk
import           Sepa.BillingConcept
import           Sepa.Controller.BillingConcept
import           Sepa.Controller.Class
import           Sepa.Controller.TreeView
import           Sepa.Creditor
import           Sepa.Debtor
import           Sepa.DirectDebit

data DirectDebitsController =
  DD
  { panelId_ :: PanelId
  , builder_ :: Builder
  , itemsTv  :: TreeView
  , itemsLs  :: ListStore Item
  }

data Item =
  Item
  { itemLastName  :: T.Text
  , itemFirstName :: T.Text
  , itemMandate   :: Mandate
  , item          :: BillingConcept
  }

instance Controller DirectDebitsController where

  type E DirectDebitsController = DirectDebitSet

  type S DirectDebitsController = ComboBox

  data D DirectDebitsController =
    DDD
    { descriptionD  :: T.Text
    , creationTimeD :: C.ZonedTime
    , debitsD       :: [DirectDebit]
    }

  builder = builder_

  panelId = panelId_

  selector = getGladeObject castToComboBox "_Cb"

  setSelectorModel s m _c = comboBoxSetModel s (Just m)

  setSelectorRenderers comboBox listStore _c = do
    renderer <- cellRendererTextNew
    cellLayoutPackStart comboBox renderer False
    let renderFunc = T.unpack . (^. description) . DB.entityVal
    cellLayoutSetAttributes comboBox renderer listStore (\row -> [cellText := renderFunc row])

  setSelectorSorting _comboBox listStore sortedModel _c = do
    let renderFunc = T.unpack . (^. description) . DB.entityVal
    treeSortableSetSortFunc sortedModel 0 $ \xIter yIter -> do
      xRow <- customStoreGetRow listStore xIter
      yRow <- customStoreGetRow listStore yIter
      return $ compare (renderFunc xRow) (renderFunc yRow)

  renderers _ = do
    let zonedTimeToGregorian = C.showGregorian . C.localDay . C.zonedTimeToLocalTime
    return [ T.unpack             . (^. description)  . DB.entityVal
           , zonedTimeToGregorian . (^. creationTime) . DB.entityVal
           ]

  editEntries c = do
    e1 <- getGladeObject castToEntry "_EE_descriptionEn" c
    e2 <- getGladeObject castToEntry "_EE_editionDateEn" c
    return [e1, e2]

  editWidgets c = do
    w1 <- getGladeObject castToTreeView "_debtorsTv"         c
    w2 <- getGladeObject castToTreeView "_billingConceptsTv" c
    w3 <- getGladeObject castToTreeView "_itemsTv"           c
    return [toWidget w1, toWidget w2, toWidget w3]

  selectWidgets c = do
    w1 <- getGladeObject castToButton "_cloneBt" c
    w2 <- getGladeObject castToButton "_printBt" c
    return [toWidget w1, toWidget w2]

  readData [descriptionEn, _] c = do
    description_ <- get descriptionEn entryText
    today <- C.getZonedTime
    -- let today  = C.localDay (C.zonedTimeToLocalTime zonedTime)
    let sameDebtor (Item last1 first1 _ _) (Item last2 first2 _ _)
          = last1 == last2 && first1 == first2
    items_  <- listStoreToList (itemsLs c)
    let items' = groupBy sameDebtor items_
    debits_ <- forM items' $ \itL -> do
      -- TRUST: the use of goupBy ensures that length itL >= 0
      let it = head itL
      -- TRUST: no invalid debits can be created (so we don't call validDirectDebit)
      return $ mkDirectDebit (itemFirstName it) (itemLastName it) (itemMandate it) (map item itL)
    return DDD { descriptionD  = T.pack description_
               , creationTimeD = today
               , debitsD       = debits_ }

  readData _ _  = error "readData (DD): wrong number of entries"

  -- Impossible to create invalid direct debit set with the GUI interface.
  validData _ _ = return True

  createFromData (DDD description_ creation_ debits_) db _c = do
    mCreditor <- flip DB.runMongoDBPoolDef db $ DB.selectFirst ([] :: [DB.Filter Creditor]) []
    case mCreditor of
      Nothing        -> error "DirectDebitsController::createFromData: no creditor"
      Just creditor_ ->
        return $ mkDirectDebitSet description_ creation_ (DB.entityVal creditor_) debits_

  updateFromData d _old = createFromData d

  selectElement iter comboBox _sortedModel _c = comboBoxSetActiveIter comboBox iter

  connectSelector comboBox sortedModel setState _c = do
    let onSelectionChangedAction = do
          mIter <- comboBoxGetActiveIter comboBox
          case mIter of
            (Just iter) -> do
              childIter <- treeModelSortConvertIterToChildIter sortedModel iter
              setState (Sel childIter)
            Nothing   -> return ()
    _ <- on comboBox changed onSelectionChangedAction
    return onSelectionChangedAction

  putElement' iter ls c = do
    ddsE <- treeModelGetRow ls iter
    let dds = DB.entityVal ddsE
    listStoreClear (itemsLs c)
    forM_ (dds ^.. debits.traverse) $ \dd ->
      forM_ (dd ^.. items.traverse) $ \bc -> do
        let item_ = Item { itemLastName    = dd ^. debtorLastName
                         , itemFirstName   = dd ^. debtorFirstName
                         , itemMandate     = dd ^. mandate
                         , item            = bc}
        listStoreAppend (itemsLs c) item_
    let debits_ = dds ^. debits
    basePriceEn_      <- getGladeObject castToEntry "_basePriceEn"      c
    finalPriceEn_     <- getGladeObject castToEntry "_finalPriceEn"     c
    numberOfDebitsEn_ <- getGladeObject castToEntry "_numberOfDebitsEn" c
    set basePriceEn_  [entryText := T.unpack . priceToText $ sumOf (traverse.items.traverse.basePrice)  debits_]
    set finalPriceEn_ [entryText := T.unpack . priceToText $ sumOf (traverse.items.traverse.finalPrice) debits_]
    set numberOfDebitsEn_ [entryText := show (length debits_)]

-- | Calls Controller::mkController and then adds special functionality for direct debit
-- sets.
mkController' :: (TreeModelClass (bcModel (DB.Entity Sepa.BillingConcept.BillingConcept)),
                  TreeModelClass (deModel (DB.Entity Sepa.Debtor.Debtor)),
                  TypedTreeModelClass bcModel, TypedTreeModelClass deModel) =>
                 DB.ConnectionPool
              -> (MainWindowState -> IO ())
              -> DirectDebitsController
              -> bcModel (DB.Entity Sepa.BillingConcept.BillingConcept)
              -> deModel (DB.Entity Sepa.Debtor.Debtor)
              -> IO ()
mkController' db setMainState c bcLs deLs = do
  _ <- mkController db setMainState c
  let orderings = repeat compare -- TODO: catalan collation

  -- FIXME: use treeModelFilterRefilter every time deLs and bcLs could have changed

  -- billing concepts TreeView
  bcTv   <- getGladeObject castToTreeView "_billingConceptsTv" c
  bcSm   <- treeModelSortNewWithModel bcLs
  let bcRf = [ T.unpack      . (^. longName)   . DB.entityVal
             , priceToString . (^. basePrice)  . DB.entityVal
             , priceToString . (^. finalPrice) . DB.entityVal
             ]
  treeViewSetModel          bcTv              bcSm
  setTreeViewRenderers      bcTv bcLs                        bcRf
  setTreeViewSorting        bcTv bcLs Nothing bcSm orderings bcRf

  -- debtors TreeView
  deTv   <- getGladeObject castToTreeView "_debtorsTv" c
  let deRf = [ T.unpack      . (^. lastName)   . DB.entityVal
             , T.unpack      . (^. firstName)  . DB.entityVal
             ]
  deFm   <- treeModelFilterNew deLs []
  zonedTime <- C.getZonedTime
  let today  = C.localDay (C.zonedTimeToLocalTime zonedTime)
  treeModelFilterSetVisibleFunc deFm $ \iter -> do
    entity <- treeModelGetRow deLs iter
    return $ isJust (getActiveMandate today (DB.entityVal entity))
  deSm  <- treeModelSortNewWithModel deFm
  treeViewSetModel           deTv                  deSm
  setTreeViewRenderers       deTv deLs                            deRf
  setTreeViewSorting         deTv deLs (Just deFm) deSm orderings deRf

  cloneBt <- getGladeObject castToButton "_cloneBt" c
  _ <- on cloneBt buttonActivated $ do
    incrementCreditorMessageCount db
    return ()

  return ()
