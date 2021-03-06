# constructor of the matrix representation
#
# initial version: YR 22/11/2010
# - YR 14 Jan 2014: moved to lav_model.R
# - YR 18 Nov 2014: more efficient handling of linear equality constraints
# - YR 02 Dec 2014: allow for bare-minimum parameter tables

# construct MATRIX representation of the model
lav_model <- function(lavpartable      = NULL,
                      representation   = "LISREL",
                      conditional.x    = FALSE,
                      th.idx           = list(),
                      parameterization = "delta",
                      link             = "logit",
                      control          = list(),
                      debug            = FALSE) {

    # handle bare-minimum partables
    lavpartable <- lav_partable_complete(lavpartable)
 
    # global info from user model
    ngroups <- max(lavpartable$group)
    meanstructure <- any(lavpartable$op == "~1")
    categorical <- any(lavpartable$op == "|")
    if(categorical) meanstructure <- TRUE
    group.w.free <- any(lavpartable$lhs == "group" & lavpartable$op == "%")


    # handle variable definitions and (in)equality constraints
    CON <- lav_constraints_parse(partable = lavpartable,
                                 constraints = NULL,
                                 debug = debug)

    # handle *linear* equality constraints special
    if(CON$ceq.linear.only.flag) {
        con.jac <- CON$ceq.JAC
        con.lambda <- numeric(nrow(CON$ceq.JAC))
        attr(con.jac, "inactive.idx") <- integer(0L)
        attr(con.jac, "ceq.idx") <- seq_len( nrow(CON$ceq.JAC) )
    } else {
        con.jac <- matrix(0,0,0)
        con.lambda <- numeric(0)
    }

    # select model matrices
    if(representation == "LISREL") {
        REP <- representation.LISREL(lavpartable, target=NULL, extra=TRUE)
    } else {
        stop("lavaan ERROR: only representation \"LISREL\" has been implemented.")
    }
    if(debug) print(REP)

    # FIXME: check for non-existing parameters
    bad.idx <- which(REP$mat == "" & 
                     !lavpartable$op %in% c("==","<",">",":="))

    if(length(bad.idx) > 0L) {
        
        label <- paste(lavpartable$lhs[bad.idx[1]], 
                       lavpartable$op[bad.idx[1]],
                       lavpartable$rhs[bad.idx[1]], sep = " ")
        stop("lavaan ERROR: parameter is not defined: ", label)
    }

    # prepare nG-sized slots
    nG <- sum(unlist(attr(REP, "mmNumber")))
    GLIST <- vector(mode="list", nG)
    names(GLIST) <- unlist(attr(REP, "mmNames"))
    dimNames    <- vector(mode="list", length=nG)
    isSymmetric <- logical(nG)
    mmSize      <- integer(nG)

    m.free.idx <- m.user.idx <- vector(mode="list", length=nG)
    x.free.idx <- x.user.idx <- vector(mode="list", length=nG)

    # prepare ngroups-sized slots
    nvar <- integer(ngroups)
    nmat <- unlist(attr(REP, "mmNumber"))
    num.idx <- vector("list", length=ngroups)
    nexo <- integer(ngroups)
    ov.x.dummy.ov.idx <- vector(mode="list", length=ngroups)
    ov.x.dummy.lv.idx <- vector(mode="list", length=ngroups)
    ov.y.dummy.ov.idx <- vector(mode="list", length=ngroups)
    ov.y.dummy.lv.idx <- vector(mode="list", length=ngroups)

    offset <- 0L
    for(g in 1:ngroups) {

        # observed and latent variables for this group
        ov.names <- vnames(lavpartable, "ov", group=g)
        ov.names.nox <- vnames(lavpartable, "ov.nox", group=g)
        ov.names.x <- vnames(lavpartable, "ov.x", group=g)
        nexo[g] <- length(ov.names.x)
        ov.num <- vnames(lavpartable, "ov.num", group=g)
        if(conditional.x) {
            nvar[g] <- length(ov.names.nox)
        } else {
            nvar[g] <- length(ov.names)
        }
        num.idx[[g]] <- match(ov.num, ov.names.nox)

        # model matrices for this group
        mmNumber    <- attr(REP, "mmNumber")[[g]]
        mmNames     <- attr(REP, "mmNames")[[g]]
        mmSymmetric <- attr(REP, "mmSymmetric")[[g]]
        mmDimNames  <- attr(REP, "mmDimNames")[[g]]
        mmRows      <- attr(REP, "mmRows")[[g]]
        mmCols      <- attr(REP, "mmCols")[[g]]

        for(mm in 1:mmNumber) {

            # offset in GLIST
            offset <- offset + 1L

            # matrix size, symmetric, dimNames
            if(mmSymmetric[mm]) {
                N <- mmRows[mm]
                mm.size <- as.integer(N*(N+1)/2)
            } else {
                mm.size <- as.integer(mmRows[mm] * mmCols[mm])
            }
            mmSize[offset] <- mm.size
            isSymmetric[offset] <- mmSymmetric[mm]
            dimNames[[offset]] <- mmDimNames[[mm]]

            # select elements for this matrix
            idx <- which(lavpartable$group == g & REP$mat == mmNames[mm]) 

            # create empty `pattern' matrix
            # FIXME: one day, we may want to use sparse matrices...
            #        but they should not slow things down!
            tmp <- matrix(0L, nrow=mmRows[mm],
                              ncol=mmCols[mm])

            # 1. first assign free values only, to get vector index
            #    -> to be used in lav_model_objective
            tmp[ cbind(REP$row[idx], REP$col[idx]) ] <- lavpartable$free[idx]
            if(mmSymmetric[mm]) {
                # NOTE: we assume everything is in the UPPER tri!
                T <- t(tmp); tmp[lower.tri(tmp)] <- T[lower.tri(T)]
            }
            m.free.idx[[offset]] <-     which(tmp > 0)
            x.free.idx[[offset]] <- tmp[which(tmp > 0)]

            # 2. if equality constraints, unconstrained free parameters
            #    -> to be used in lav_model_gradient
            #if(CON$ceq.linear.only.flag) {
            #    tmp[ cbind(REP$row[idx], 
            #               REP$col[idx]) ] <- lavpartable$unco[idx]
            #    if(mmSymmetric[mm]) {
            #        # NOTE: we assume everything is in the UPPER tri!
            #        T <- t(tmp); tmp[lower.tri(tmp)] <- T[lower.tri(T)]
            #    }
            #    m.unco.idx[[offset]] <-     which(tmp > 0)
            #    x.unco.idx[[offset]] <- tmp[which(tmp > 0)]
            #} else {
            #    m.unco.idx[[offset]] <- m.free.idx[[offset]]
            #    x.unco.idx[[offset]] <- x.free.idx[[offset]]
            #}

            # 3. general mapping between user and GLIST
            tmp[ cbind(REP$row[idx], REP$col[idx]) ] <- lavpartable$id[idx]
            if(mmSymmetric[mm]) {
                T <- t(tmp); tmp[lower.tri(tmp)] <- T[lower.tri(T)]
            }
            m.user.idx[[offset]] <-     which(tmp > 0)
            x.user.idx[[offset]] <- tmp[which(tmp > 0)]
          
            # 4. now assign starting/fixed values
            # create empty matrix
            # FIXME: again, we may want to use sparse matrices here...
            tmp <- matrix(0.0, nrow=mmRows[mm],
                               ncol=mmCols[mm])
            tmp[ cbind(REP$row[idx], REP$col[idx]) ] <- lavpartable$start[idx]
            if(mmSymmetric[mm]) {
                T <- t(tmp); tmp[lower.tri(tmp)] <- T[lower.tri(T)]
            }

            # representation specific stuff
            if(representation == "LISREL" && mmNames[mm] == "lambda") { 
                ov.dummy.names.nox <- attr(REP, "ov.dummy.names.nox")[[g]]
                ov.dummy.names.x   <- attr(REP, "ov.dummy.names.x")[[g]]
                ov.dummy.names <- c(ov.dummy.names.nox, ov.dummy.names.x)
                # define dummy latent variables
                if(length(ov.dummy.names)) {
                    # in this case, lv.names will be extended with the dummys
                    LV.names <- mmDimNames$psi[[1]]
                    row..idx <- match(ov.dummy.names, ov.names)
                    col..idx <- match(ov.dummy.names, LV.names)
                    # Fix lambda values to 1.0
                    tmp[ cbind(row..idx, col..idx)] <- 1.0

                    ov.x.dummy.ov.idx[[g]] <- match(ov.dummy.names.x,ov.names)
                    ov.x.dummy.lv.idx[[g]] <- match(ov.dummy.names.x,LV.names)
                    ov.y.dummy.ov.idx[[g]] <- match(ov.dummy.names.nox,ov.names)
                    ov.y.dummy.lv.idx[[g]] <- match(ov.dummy.names.nox,LV.names)
                }
            }

            # representation specific
            if(representation == "LISREL" && mmNames[mm] == "delta") {
                # only categorical values are listed in the lavpartable
                # but all remaining values should be 1.0
                idx <- which(tmp[,1L] == 0.0)
                tmp[idx,1L] <- 1.0    
            }
            
            # assign matrix to GLIST
            GLIST[[offset]] <- tmp
        } # mm
    } # g

    # fixed.x parameters?
    fixed.x <- any(lavpartable$exo > 0L & lavpartable$free == 0L) 
    if(categorical) {
        fixed.x <- TRUE
    }


    Model <- new("Model",
                 GLIST=GLIST,
                 dimNames=dimNames,
                 isSymmetric=isSymmetric,
                 mmSize=mmSize,
                 representation=representation,
                 meanstructure=meanstructure,
                 categorical=categorical,
                 link=link,
                 control=control,
                 ngroups=ngroups,
                 group.w.free=group.w.free,
                 nmat=nmat,
                 nvar=nvar,
                 num.idx=num.idx,
                 th.idx=th.idx,
                 nx.free=max(lavpartable$free),
                 #nx.unco=max(lavpartable$unco),
                 nx.user=max(lavpartable$id),
                 m.free.idx=m.free.idx,
                 x.free.idx=x.free.idx,
                 #m.unco.idx=m.unco.idx,
                 #x.unco.idx=x.unco.idx,
                 m.user.idx=m.user.idx,
                 x.user.idx=x.user.idx,
                 x.def.idx=which(lavpartable$op == ":="),
                 x.ceq.idx=which(lavpartable$op == "=="),
                 x.cin.idx=which(lavpartable$op == ">" | lavpartable$op == "<"),

                 eq.constraints      = CON$ceq.linear.only.flag,
                 eq.constraints.K    = CON$ceq.JAC.NULL,
                 eq.constraints.k0   = CON$ceq.rhs.NULL,

                 def.function        = CON$def.function,
                 ceq.function        = CON$ceq.function,
                 ceq.JAC             = CON$ceq.JAC,
                 ceq.rhs             = CON$ceq.rhs,
                 ceq.jacobian        = CON$ceq.jacobian,
                 ceq.linear.idx      = CON$ceq.linear.idx,
                 ceq.nonlinear.idx   = CON$ceq.nonlinear.idx,

                 cin.function        = CON$cin.function,
                 cin.JAC             = CON$cin.JAC,
                 cin.rhs             = CON$cin.rhs,
                 cin.jacobian        = CON$cin.jacobian,
                 cin.linear.idx      = CON$cin.linear.idx,
                 cin.nonlinear.idx   = CON$cin.nonlinear.idx,

                 con.jac             = con.jac,
                 con.lambda          = con.lambda,

                 nexo                = nexo,
                 fixed.x             = fixed.x,
                 conditional.x       = conditional.x,
                 #x.idx               = x.idx,
                 parameterization    = parameterization,

                 ov.x.dummy.ov.idx   = ov.x.dummy.ov.idx,
                 ov.x.dummy.lv.idx   = ov.x.dummy.lv.idx,
                 ov.y.dummy.ov.idx   = ov.y.dummy.ov.idx,
                 ov.y.dummy.lv.idx   = ov.y.dummy.lv.idx)

    if(debug) {
         cat("lavaan DEBUG: lavaanModel\n")
         print( str(Model) )
         print( Model@GLIST )
    }

    Model
}

# for backwards compatibility
# Model <- lav_model
