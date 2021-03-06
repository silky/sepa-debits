{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

module Sepa.Controller.Class where

import           Control.Monad
import           Data.Char                (isDigit)
import           Data.IORef
import qualified Data.Text as T
import qualified Database.Persist.MongoDB as DB
import           Graphics.UI.Gtk

type PanelId = String

data MainWindowState
  = View { _choosedPanelId :: PanelId }
  | Edit { _choosedPanelId :: PanelId }

--makeLenses ''MainWindowState

-- | Option @Sel@ stores a @ListStore@ (child) iter.
data PanelState c
  = NoSel
  | Sel     { _iter :: TreeIter }
  | EditNew { _data :: D c, _isValid :: Bool }
  | EditOld { _iter :: TreeIter, _isValid :: Bool }
  | EditSub { _iter :: TreeIter, _isValid :: Bool }

--makeLenses ''PanelState

type PS c = DB.Entity (E c)     -- ^ Used to simplify type signatures in Controller.

type LS c = ListStore (PS c)    -- ^ Used to simplify type signatures in Controller.

-- | Generic panel controller, used to factorize implementation of debtors, billing
-- concepts and direct debits panels (an VBox with all its contained widgets). It's main
-- entry point is template method @mkController@. In general, functions in this class are
-- non-pure, as they use state stored by Gtk in the IO monad. The class is parametrized
-- (through associated types) with an entity type, a @selector@ (e.g. TreeView) type, and
-- type for raw data (as read from the GUI) associated to an entity.
class (DB.PersistEntity (E c), DB.PersistEntityBackend (E c) ~ DB.MongoBackend, WidgetClass (S c)) =>
      Controller c where

  -- | Entity type, i.e., type of the elements shown in the panel (e.g Debtor).
  type E c

  -- | Type of the selector widget (e.g. TreeView or ComboBox).
  type S c

  -- | Type for raw data taken from entries, representing an entity of type E c.
  data D c

  -- All instances need to implement, at least, the following functions
  panelId              ::                                                     c -> PanelId
  -- ^ Instances need to implement this.
  builder              ::                                                     c -> Builder
  -- ^ Instances need to implement this.
  selector             ::                                                     c -> IO (S c)
  setSelectorModel     :: (TreeModelClass m)      => S c         -> m      -> c -> IO ()
  connectSelector      :: (TreeModelSortClass sm) => S c         -> sm
                       -> (PanelState c -> IO ())                          -> c -> IO (IO ())
  readData             :: [Entry]                                          -> c -> IO (D c)
  validData            :: D c                                              -> c -> IO Bool
  -- FIXME: DB.ConnectionPool used only to get Creditor in DirectDebitsController
  createFromData       :: D c                         -> DB.ConnectionPool -> c -> IO (E c)
  updateFromData       :: D c -> E c                  -> DB.ConnectionPool -> c -> IO (E c)
  selectElement        :: (TreeModelSortClass sm) => TreeIter -> S c -> sm -> c -> IO ()

  -- The following functions may be re-implemented, default instance implementation does
  -- nothing
  setSelectorRenderers ::                            S c -> LS c           -> c -> IO ()
  setSelectorSorting   :: (TreeSortableClass sm)  => S c -> LS c -> sm     -> c -> IO ()
  setSelectorSearching :: (TreeModelSortClass sm) => S c -> LS c -> sm     -> c -> IO ()
  editEntries          ::                                                     c -> IO [Entry]
  priceEntries         ::                                                     c -> IO [Entry]
  editWidgets          ::                                                     c -> IO [Widget]
  selectWidgets        ::                                                     c -> IO [Widget]
  renderers            ::                                                     c -> IO [PS c -> String]
  putSubElement        :: TreeIter -> LS c                                 -> c -> IO ()
  putElement'          :: TreeIter -> LS c                                 -> c -> IO ()
  mkSubElemController  :: (TreeModelSortClass sm) =>
                          LS c -> sm -> DB.ConnectionPool
                       -> IORef (PanelState c) -> (PanelState c -> IO ())  -> c -> IO ()
  subElemButtons       ::                                                     c -> IO [ToggleButton]
  setSubElemState      :: PanelState c                                     -> c -> IO ()

  -- The following functions have a generally applicable default implementation. Some of
  -- them ar based on conventions for Glade names.
  panel                ::                                                     c -> IO VBox
  chooser              ::                                                     c -> IO ToggleButton
  newTb                ::                                                     c -> IO ToggleButton
  editTb               ::                                                     c -> IO ToggleButton
  deleteBt             ::                                                     c -> IO Button
  saveBt               ::                                                     c -> IO Button
  cancelBt             ::                                                     c -> IO Button
  deleteDg             ::                                                     c -> IO Dialog
  elements             :: DB.ConnectionPool                                -> c -> IO [PS c]
  putElement           :: TreeIter -> LS c -> [PS c -> String]  -> [Entry] -> c -> IO ()
  deleteElement        :: TreeIter -> LS c -> DB.ConnectionPool            -> c -> IO ()
  insertElement        ::             LS c -> DB.ConnectionPool -> [Entry] -> c -> IO TreeIter
  updateElement        :: TreeIter -> LS c -> DB.ConnectionPool -> [Entry] -> c -> IO TreeIter

  -- | A Template Method pattern (it is implemented once for all instances) that
  -- initializes all the panel widgets, including connection with persistent model and
  -- callback events. All the other functions in this class are here only to be called by
  -- @mkController@, except @panelId@, @panel@ and @chooser@.
  mkController         :: (Controller c, TreeModelSortClass sm, sm ~ TypedTreeModelSort (PS c)) =>
                          DB.ConnectionPool -> (MainWindowState -> IO ()) -> c
                       -> IO (PanelState c -> IO (), IORef (PanelState c), LS c, sm)

  -- Default implementations for some functions

  setSelectorRenderers _ _ _      = return ()

  setSelectorSorting   _ _ _ _    = return ()

  setSelectorSearching _ _ _ _    = return ()

  editEntries _                   = return []

  priceEntries _                  = return []

  editWidgets _                   = return []

  selectWidgets _                 = return []

  subElemButtons _                = return []

  renderers _                     = return []

  putSubElement _ _ _             = return ()

  putElement'   _ _ _             = return ()

  mkSubElemController _ _ _ _ _ _ = return ()

  setSubElemState _ _             = return ()

  panel   c      = builderGetObject (builder c) castToVBox         (panelId c ++ "_Vb")

  chooser c      = builderGetObject (builder c) castToToggleButton (panelId c ++ "_Tb")

  newTb          = getGladeObject castToToggleButton "_newTb"

  editTb         = getGladeObject castToToggleButton "_editTb"

  deleteBt       = getGladeObject castToButton       "_deleteBt"

  saveBt         = getGladeObject castToButton       "_saveBt"

  cancelBt       = getGladeObject castToButton       "_cancelBt"

  deleteDg c     = builderGetObject (builder c) castToDialog "deleteDg"

  elements db _c = flip DB.runMongoDBPoolDef db $ DB.selectList ([] :: [DB.Filter (E c)]) []

  putElement iter ls renderers_ entries c = do
    entity <- treeModelGetRow ls iter
    forM_ (zip entries renderers_) $ \(e, r) -> set e [entryText := r entity]
    putSubElement iter ls c
    putElement'   iter ls c

  deleteElement iter ls db _ = do
    entity <- treeModelGetRow ls iter
    flip DB.runMongoDBPoolDef db $ DB.delete (DB.entityKey entity)
    let index = listStoreIterToIndex iter
    listStoreRemove ls index

  insertElement ls db entries c = do
    data_ <- readData entries c  -- Assume data is valid
    val   <- createFromData data_ db c
    key   <- flip DB.runMongoDBPoolDef db $ DB.insert val -- FIXME: check unique constraints
    index <- listStoreAppend ls (DB.Entity key val)
    let treePath = stringToTreePath (T.pack (show index))
    Just iter <- treeModelGetIter ls treePath
    return iter

  updateElement iter ls db entries c = do
    dataNew <- readData entries c  -- Assume data is valid
    old     <- treeModelGetRow ls iter
    new     <- updateFromData dataNew (DB.entityVal old) db c
    flip DB.runMongoDBPoolDef db $ DB.replace (DB.entityKey old) new
    let index = listStoreIterToIndex iter
    listStoreSetValue ls index (DB.Entity (DB.entityKey old) new)
    return iter

  mkController = mkControllerImpl -- Implemented as a top-level function

mkControllerImpl :: forall c sm . (Controller c, TreeModelSortClass sm, sm ~ TypedTreeModelSort (PS c),
                     DB.PersistEntity (E c), DB.PersistEntityBackend (E c) ~ DB.MongoBackend) =>
                    DB.ConnectionPool -> (MainWindowState -> IO ()) -> c
                 -> IO (PanelState c -> IO (), IORef (PanelState c), LS c, sm)
mkControllerImpl db setMainWdState c = do
  selector_  <- selector c
  e          <- elements db c
  ls         <- listStoreNew e
  sm         <- treeModelSortNewWithModel ls

  setSelectorModel     selector_    sm c
  setSelectorRenderers selector_ ls    c
  setSelectorSorting   selector_ ls sm c
  setSelectorSearching selector_ ls sm c

  let panelId_ = panelId c
  newTb_           <- newTb c
  editTb_          <- editTb c
  deleteBt_        <- deleteBt c
  saveBt_          <- saveBt c
  cancelBt_        <- cancelBt c
  rs               <- renderers c
  editEntries_     <- editEntries c
  priceEntries_    <- priceEntries c
  editWidgets_     <- editWidgets c
  selectWidgets_   <- selectWidgets c
  deleteDg_        <- deleteDg c
  subElemButtons_  <- subElemButtons c

  -- Place panel initial state in an IORef

  stRef <- newIORef NoSel :: IO (IORef (PanelState c))

  -- Panel state function.
  -- FIXME: don't call setMainWdState if not necessary
  let setState' :: PanelState c -> IO ()
      setState' st@NoSel = do
        putStrLn "NoSel"
        forM_ editEntries_                    (`set` [widgetSensitive    := False, entryText := ""])
        forM_ editWidgets_                    (`set` [widgetSensitive    := False])
        forM_ selectWidgets_                  (`set` [widgetSensitive    := False])
        forM_ [deleteBt_, saveBt_, cancelBt_] (`set` [widgetSensitive    := False])
        forM_ [editTb_]                       (`set` [widgetSensitive    := False])
        forM_ [selector_]                     (`set` [widgetSensitive    := True ])
        forM_ [newTb_]                        (`set` [widgetSensitive    := True ])
        forM_ [editTb_, newTb_]               (`set` [toggleButtonActive := False])
        forM_ subElemButtons_                 (`set` [widgetSensitive    := False])
        forM_ subElemButtons_                 (`set` [toggleButtonActive := False])
        setSubElemState st c
        setMainWdState (View panelId_)
      setState' st@(Sel iter) = do
        putStrLn "Sel"
        putElement iter ls rs editEntries_ c
        forM_ editEntries_                    (`set` [widgetSensitive    := False])
        forM_ editWidgets_                    (`set` [widgetSensitive    := False])
        forM_ [saveBt_, cancelBt_]            (`set` [widgetSensitive    := False])
        forM_ selectWidgets_                  (`set` [widgetSensitive    := True ])
        forM_ [selector_]                     (`set` [widgetSensitive    := True ])
        forM_ [editTb_, newTb_]               (`set` [widgetSensitive    := True ])
        forM_ [deleteBt_]                     (`set` [widgetSensitive    := True ])
        forM_ [editTb_, newTb_]               (`set` [toggleButtonActive := False])
        forM_ subElemButtons_                 (`set` [widgetSensitive    := True ])
        forM_ subElemButtons_                 (`set` [toggleButtonActive := False])
        setSubElemState st c
        setMainWdState (View panelId_)
      setState' st@(EditNew _iter valid) = do
        putStrLn "EditNew"
        forM_ selectWidgets_                  (`set` [widgetSensitive    := False])
        forM_ [selector_]                     (`set` [widgetSensitive    := False])
        forM_ [editTb_, newTb_]               (`set` [widgetSensitive    := False])
        forM_ [deleteBt_]                     (`set` [widgetSensitive    := False])
        forM_ editWidgets_                    (`set` [widgetSensitive    := True ])
        forM_ [saveBt_]                       (`set` [widgetSensitive    := valid])
        forM_ [cancelBt_]                     (`set` [widgetSensitive    := True ])
        forM_ subElemButtons_                 (`set` [widgetSensitive    := False])
        forM_ subElemButtons_                 (`set` [toggleButtonActive := False])
        setSubElemState st c
        setMainWdState (Edit panelId_)
      setState' st@(EditOld _iter valid) = do
        putStrLn "EditOld"
        forM_ selectWidgets_                  (`set` [widgetSensitive    := False])
        forM_ [selector_]                     (`set` [widgetSensitive    := False])
        forM_ [editTb_, newTb_]               (`set` [widgetSensitive    := False])
        forM_ [deleteBt_]                     (`set` [widgetSensitive    := False])
        forM_ editEntries_                    (`set` [widgetSensitive    := True ])
        forM_ editWidgets_                    (`set` [widgetSensitive    := True ])
        forM_ [saveBt_]                       (`set` [widgetSensitive    := valid])
        forM_ [cancelBt_]                     (`set` [widgetSensitive    := True ])
        forM_ subElemButtons_                 (`set` [widgetSensitive    := False])
        forM_ subElemButtons_                 (`set` [toggleButtonActive := False])
        setSubElemState st c
        setMainWdState (Edit panelId_)
      setState' st@(EditSub _iter _valid) = do
        putStrLn "EditSub"
        forM_ editEntries_                    (`set` [widgetSensitive    := False])
        forM_ editWidgets_                    (`set` [widgetSensitive    := False])
        forM_ [saveBt_, cancelBt_]            (`set` [widgetSensitive    := False])
        forM_ selectWidgets_                  (`set` [widgetSensitive    := False])
        forM_ [selector_]                     (`set` [widgetSensitive    := False])
        forM_ [editTb_, newTb_]               (`set` [widgetSensitive    := False])
        forM_ [deleteBt_]                     (`set` [widgetSensitive    := False])
        forM_ [editTb_, newTb_]               (`set` [toggleButtonActive := False])
        forM_ subElemButtons_                 (`set` [widgetSensitive    := True ])
        forM_ subElemButtons_                 (`set` [toggleButtonActive := True ])
        setSubElemState st c
        setMainWdState (Edit panelId_)
  let setState :: PanelState c -> IO ()
      setState newSt = do
        setState' newSt
        writeIORef stRef newSt

  -- Set panel initial state

  st <- readIORef stRef
  setState st

  -- Connect panel widgets

  -- On insert on price entries, check if digit or separator
  priceEntriesIdRefs <- forM priceEntries_ mkPriceEntry
  forM_ priceEntriesIdRefs $ \ref -> do { id_ <- readIORef ref; signalBlock id_ }

  onSelectionChangedAction <- connectSelector selector_ sm setState c

  -- Change state if validation state changes (check at every edit)
  handlers <- forM editEntries_ $ \entry -> on entry editableChanged $ do
    st'    <- readIORef stRef
    d      <- readData editEntries_ c
    v      <- validData d c
    case (st', v) of
      (EditNew s vOld, vNew) | vNew /= vOld -> setState (EditNew s vNew)
      (EditOld i vOld, vNew) | vNew /= vOld -> setState (EditOld i vNew)
      _                                     -> return ()

  forM_ handlers signalBlock

  _ <- on cancelBt_ buttonActivated $ do
       forM_ handlers signalBlock
       forM_ priceEntriesIdRefs $ \ref -> do { id_ <- readIORef ref; signalBlock id_ }
       onSelectionChangedAction

  _ <- on editTb_ toggled $ do
    isActive <- toggleButtonGetActive editTb_
    when isActive $ do
      Sel iter <- readIORef stRef -- FIXME: unsafe pattern
      -- OLD: elem <- treeModelGetRow ls iter
      -- OLD: let valid = validStrings (itemToStrings item)
      -- Assume that before an Edit has been a Sel that has filled editEntries
      d <- readData editEntries_ c
      v <- validData d c
      setState (EditOld iter v)
      forM_ handlers signalUnblock
      forM_ priceEntriesIdRefs $ \ref -> do { id_ <- readIORef ref; signalUnblock id_ }

  _ <- on newTb_ toggled $ do
    isActive <- toggleButtonGetActive newTb_
    when isActive $ do
      -- OLD: let s = guiNewItemToStrings gui
      forM_ editEntries_ (`set` [widgetSensitive    := True, entryText := ""])
      d <- readData editEntries_ c
      v <- validData d c
      setState (EditNew d v)
      forM_ handlers signalUnblock
      forM_ priceEntriesIdRefs $ \ref -> do { id_ <- readIORef ref; signalUnblock id_ }

  _ <- on deleteBt_ buttonActivated $ do
    (Sel iter) <- readIORef stRef -- FIXME: unsafe pattern
    resp <- dialogRun deleteDg_
    widgetHide deleteDg_
    when (resp == ResponseOk) $ do
      deleteElement iter ls db c
      setState NoSel

  _ <- on saveBt_ buttonActivated $ do
    forM_ handlers signalBlock
    forM_ priceEntriesIdRefs $ \ref -> do { id_ <- readIORef ref; signalBlock id_ }
    st' <- readIORef stRef
    iter <- case st' of
      EditNew _    True -> insertElement      ls db editEntries_ c
      EditOld iter True -> updateElement iter ls db editEntries_ c
      _                 -> error "mkControllerImpl: Unexpected state when saving"
    selectElement iter selector_ sm c
    setState (Sel iter)

  forM_ subElemButtons_ $ \button -> do
    _ <- on button toggled $ do
      isActive <- toggleButtonGetActive button
      when isActive $ do
        st' <- readIORef stRef
        case st' of
          Sel iter -> setState (EditSub iter False)
          _        -> return ()
    return ()

  mkSubElemController ls sm db stRef setState c
  return (setState, stRef, ls, sm)

mkPriceEntry :: Entry -> IO (IORef (ConnectId Entry))
mkPriceEntry entry = do
  idRef <- newIORef undefined
  id_ <- on entry insertText $ \str pos -> do
    id_ <- readIORef idRef
    signalBlock id_
    old <- editableGetChars entry 0 (-1)
    pos' <- if length str == 1 then do
        let separator = ','       -- FIXME: Take separator from locale
        let (oldI, oldF) = break (== separator) old
        let str' = case (length oldI, length oldF, pos) of
              (i, 0, p) | i - p <= 2 -> filter (\c_ -> isDigit c_ || c_ == ',') str
              (i, 0, p) | i - p >  2 -> filter isDigit str -- Sep. would be too far left
              (_, 1, _)              -> filter isDigit str -- Sep. but 0 fract. digits
              (_, 2, _)              -> filter isDigit str -- Sep. and 1 fract. digit
              (i, 3, p) | p <= i     -> filter isDigit str -- We're on integer part
              (i, 3, p) | p >  i     -> ""                 -- Too many fractional digits
              _                      -> error "on priceEntry insertText"
        editableInsertText entry str' pos
      else return pos
    signalUnblock id_
    stopInsertText id_
    return pos'
  writeIORef idRef id_
  return idRef

getGladeObject :: (GObjectClass b, Controller c) => (GObject -> b) -> String -> c -> IO b
getGladeObject cast name c =
  builderGetObject (builder c) cast (panelId c ++ name)
