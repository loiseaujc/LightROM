module LightROM_Utils
   ! stdlib
   use stdlib_linalg, only : eye, diag, svd, svdvals, is_symmetric
   use stdlib_optval, only : optval
   use stdlib_stats_distribution_normal, only: normal => rvs_normal
   use stdlib_logger, only : logger => global_logger
   ! LightKrylov for Linear Algebra
   use LightKrylov
   use LightKrylov_Constants
   use LightKrylov, only : dp, wp => dp
   use LightKrylov_Logger
   use LightKrylov_AbstractVectors
   use LightKrylov_BaseKrylov, only : orthogonalize_against_basis
   use LightKrylov_Utils, only : abstract_opts, sqrtm
   ! LightROM
   use LightROM_AbstractLTIsystems
   include "dtypes.h"
   
   implicit none 

   private :: this_module
   character(len=*), parameter :: this_module     = 'LR_Utils'
   character(len=*), parameter :: logfile_SVD_abs = 'Lyap_SVD_abs.dat'
   character(len=*), parameter :: logfile_SVD_rel = 'Lyap_SVD_rel.dat'

   public :: dlra_opts
   public :: coefficient_matrix_norm, increment_norm, low_rank_CALE_residual_norm
   public :: is_converged
   public :: write_logfile_headers
   public :: stamp_logfiles
   public :: project_onto_common_basis
   public :: Balancing_Transformation
   public :: ROM_Petrov_Galerkin_Projection
   public :: ROM_Galerkin_Projection
   public :: project_onto_common_basis

   ! Utilities for matrix norm computations
   public :: dense_frobenius_norm
   public :: increment_norm
   public :: CALE_res_norm

   ! Miscellenous utils
   public :: chk_opts
   public :: is_converged
   public :: random_low_rank_state

   interface Balancing_Transformation
      module procedure Balancing_Transformation_rdp
   end interface

   interface ROM_Petrov_Galerkin_Projection
      module procedure ROM_Petrov_Galerkin_Projection_rdp
   end interface

   interface ROM_Galerkin_Projection
      module procedure ROM_Galerkin_Projection_rdp
   end interface

   interface project_onto_common_basis
      module procedure project_onto_common_basis_rdp
   end interface

   interface random_low_rank_state
      module procedure random_low_rank_state_rdp
   end interface

   type, extends(abstract_opts), public :: dlra_opts
      !! Options container for the (rank-adaptive) projector-splitting dynalical low-rank approximation
      !! integrator
      integer :: mode = 1
      !! Time integration mode. Only 1st order (Lie splitting - mode 1) and 
      !! 2nd order (Strang splitting - mode 2) are implemented. (default: 1)
      !
      ! CONVERGENCE CHECK
      !
      integer :: chkstep = 10
      !! Time step interval at which convergence is checked and runtime information is printed (default: 10)
      real(wp) :: chktime = 1.0_wp
      !! Simulation time interval at which convergence is checked and runtime information is printed (default: 1.0)
      logical :: chkctrl_time = .true.
      !! Use time instead of timestep control (default: .true.)
      logical :: chksvd = .true.
      !! Which norm is decisive for convergence? (singular value increment - .true. - or increment norm - .false.; default = .true.)
      real(wp) :: inc_tol = 1e-6_wp
      !! Tolerance on the increment for convergence (default: 1e-6)
      logical :: relative_inc = .true.
      !! Tolerance control: Use relative values for convergence (default = .true.)
      !
      ! OUTPUT CALLBACK
      !
      logical :: ifIO = .false.
      !! Oupost during simulation (default = .false.). The final result is always returned.
      integer :: iostep = 100
      !! Time step interval at which to outpost
      real(wp) :: iotime = 1.0_wp
      !! Simulation time interval at which convergence is checked and runtime information is printed (default: 1.0)
      logical :: ioctrl_time = .true.
      !! IO control: use time instead of timestep control (default: .true.)
      logical :: ifsvd = .true.
      !! Compute the SVD and project low-rank data prior to callback
      !
      ! RANK-ADPATIVE SPECIFICS
      !
      logical :: if_rank_adaptive = .true.
      !! Allow rank-adaptivity
      !
      ! RANK-ADPATIVE SPECIFICS
      !    
      !! INITIAL RANK
      integer :: ninit = 10
      !! Number of time steps to run the integrator when determining the initial rank (default: 10)
      real(wp) :: tinit = 1.0_wp
      !! Physical time to run the integrator when determining the initial rank (default: 1.0)
      logical :: initctrl_step = .true.
      !! Init control: use ninit to determine the integration time for initial rank (default: .true.)
      !
      !! TOLERANCE
      real(wp) :: tol = 1e-6_wp
      !! Tolerance on the extra singular value to determine rank-adaptation
      integer :: err_est_step = 10
      !! Time step interval for recomputing the splitting error estimate (only of use_err_est = .true.)
      logical :: use_err_est = .false.
      !! Choose whether to base the tolerance on 'tol' or on the splitting error estimate
   end type

contains

   subroutine Balancing_Transformation_rdp(T, S, Tinv, Xc, Yo)
      !! Computes the the biorthogonal balancing transformation \( \mathbf{T}, \mathbf{T}^{-1} \) from the
      !! low-rank representation of the SVD of the controllability and observability Gramians, \( \mathbf{W}_c \) 
      !! and \( \mathbf{W}_o \) respectively, given as:
      !! \[ \begin{align}
      !!    \mathbf{W}_c &= \mathbf{X}_c \mathbf{X}_c^T \\
      !!    \mathbf{W}_o &= \mathbf{Y}_o \mathbf{Y}_o^T
      !! \end{align} \]
      !!
      !! Given the SVD of the cross-Gramian:
      !! $$ \mathbf{X}_c^T \mathbf{Y}_o = \mathbf{U} \mathbf{S} \mathbf{V}^T $$
      !! the balancing transformation and its inverse are given by:
      !! \[ \begin{align}
      !!            \mathbf{T}   &= \mathbf{X}_o \mathbf{S}_o^{1/2} \mathbf{V} \mathbf{S}^{-1/2} \\
      !!            \mathbf{Tinv}^T &= \mathbf{Y}_c \mathbf{S}_c^{1/2} \mathbf{U} \mathbf{S}^{-1/2} 
      !! \end{align} \]
      !! Note: In the current implementation, the numerical rank of the SVD is not considered.
      class(abstract_vector_rdp),          intent(out)   :: T(:)
      !! Balancing transformation
      real(wp),                            intent(out)   :: S(:)
      !! Singular values of the BT
      class(abstract_vector_rdp),          intent(out)   :: Tinv(:)
      !! Inverse balancing transformation
      class(abstract_vector_rdp),          intent(in)    :: Xc(:)
      !! Low-rank representation of the Controllability Gramian
      class(abstract_vector_rdp),          intent(in)    :: Yo(:)
      !! Low-rank representation of the Observability Gramian

      ! internal variables
      integer                                :: i, rkc, rko, rk, rkmin
      real(wp),                  allocatable :: LRCrossGramian(:,:)
      real(wp),                  allocatable :: Swrk(:,:)
      real(wp),                  allocatable :: Sigma(:)
      real(wp),                  allocatable :: V(:,:), W(:,:)

      rkc   = size(Xc)
      rko   = size(Yo)
      rk    = max(rkc, rko)
      rkmin = min(rkc, rko) 

      ! compute inner product with Gramian bases and compte SVD
      allocate(LRCrossGramian(rkc,rko)); allocate(V(rko,rko)); allocate(W(rkc,rkc))
      call innerprod(LRCrossGramian, Xc, Yo)
      call svd(LRCrossGramian, S, V, W)

      allocate(Sigma(rkmin))
      do i = 1, rkmin
         Sigma(i) = 1/sqrt(S(i))
      enddo
      block
         class(abstract_vector_rdp), allocatable :: Xwrk(:)
         call linear_combination(Xwrk, Yo(1:rkmin), matmul(W(1:rkmin,1:rkmin), diag(Sigma)))
         call copy(T(1:rkmin), Xwrk)
         call linear_combination(Xwrk, Xc(1:rkmin), matmul(V(1:rkmin,1:rkmin), diag(Sigma)))
         call copy(Tinv(1:rkmin), Xwrk)
      end block
         
      return
   end subroutine Balancing_Transformation_rdp

   subroutine ROM_Petrov_Galerkin_Projection_rdp(Ahat, Bhat, Chat, D, LTI, T, Tinv)
      !! Computes the Reduced-Order Model of the input LTI dynamical system via Petrov-Galerkin projection 
      !! using the biorthogonal projection bases \( \mathbf{V} \) and \( \mathbf{W} \) with 
      !! \( \mathbf{W}^T \mathbf{V} = \mathbf{I} \).
      !! 
      !! Given an LTI system defined by the matrices \( \mathbf{A}, \mathbf{B}, \mathbf{C}, \mathbf{D}\), 
      !! the matrices \( \hat{\mathbf{A}}, \hat{\mathbf{B}}, \hat{\mathbf{C}}, \hat{\mathbf{D}}\) of the 
      !! projected LTI system are given by:
      !! \[
      !!     \hat{\mathbf{A}} = \mathbf{W}^T \mathbf{A} \mathbf{V}, \qquad
      !!     \hat{\mathbf{B}} = \mathbf{W}^T \mathbf{B}, \qquad
      !!     \hat{\mathbf{C}} = \mathbf{C} \mathbf{V}, \qquad
      !!     \hat{\mathbf{D}} = \mathbf{D} .
      !! \]
      real(wp),            allocatable, intent(out)    :: Ahat(:, :)
      !! Reduced-order dynamics matrix.
      real(wp),            allocatable, intent(out)    :: Bhat(:, :)
      !! Reduced-order input-to-state matrix.
      real(wp),            allocatable, intent(out)    :: Chat(:, :)
      !! Reduced-order state-to-output matrix.
      real(wp),            allocatable, intent(out)    :: D(:, :)
      !! Feed-through matrix
      class(abstract_lti_system_rdp),   intent(inout)  :: LTI
      !! Large-scale LTI to project
      class(abstract_vector_rdp),       intent(in)     :: T(:)
      !! Balancing transformation
      class(abstract_vector_rdp),       intent(in)     :: Tinv(:)
      !! Inverse balancing transformation

      ! internal variables
      integer                                          :: i, rk, rkc, rkb
      class(abstract_vector_rdp),       allocatable    :: Uwrk(:)
      real(wp),                         allocatable    :: Cwrk(:, :)

      rk  = size(T)
      rkb = size(LTI%B)
      rkc = size(LTI%CT)
      allocate(Uwrk(rk), source=T(1)); call zero_basis(Uwrk)
      allocate(Ahat(1:rk, 1:rk ));                  Ahat = 0.0_wp
      allocate(Bhat(1:rk, 1:rkb));                  Bhat = 0.0_wp
      allocate(Cwrk(1:rk, 1:rkc));                  Cwrk = 0.0_wp
      allocate(Chat(1:rkc,1:rk ));                  Chat = 0.0_wp
      allocate(D(1:size(LTI%D,1),1:size(LTI%D,2))); D    = 0.0_wp

      do i = 1, rk
         call LTI%A%matvec(Tinv(i), Uwrk(i))
      end do
      call innerprod(Ahat, T, Uwrk)
      call innerprod(Bhat, T, LTI%B)
      call innerprod(Cwrk, LTI%CT, Tinv)
      Chat = transpose(Cwrk)
      D = LTI%D

   end subroutine ROM_Petrov_Galerkin_Projection_rdp

   subroutine ROM_Galerkin_Projection_rdp(Ahat, Bhat, Chat, D, LTI, T)
      !! Computes the Reduced-Order Model of the input LTI dynamical system via Galerkin projection using 
      !! the orthogonal projection basis \( \mathbf{V} \) with \( \mathbf{V}^T \mathbf{V} = \mathbf{I} \).
      !! 
      !! Given an LTI system defined by the matrices \( \mathbf{A}, \mathbf{B}, \mathbf{C}, \mathbf{D}\), 
      !! the matrices \( \hat{\mathbf{A}}, \hat{\mathbf{B}}, \hat{\mathbf{C}}, \hat{\mathbf{D}}\) of the projected LTI system is given by:
      !! \[
      !!     \hat{\mathbf{A}} = \mathbf{V}^T \mathbf{A} \mathbf{V}, \qquad
      !!     \hat{\mathbf{B}} = \mathbf{V}^T \mathbf{B}, \qquad
      !!     \hat{\mathbf{C}} = \mathbf{C} \mathbf{V}, \qquad
      !!     \hat{\mathbf{D}} = \mathbf{D} .
      !! \]
      real(wp),            allocatable, intent(out)    :: Ahat(:, :)
      !! Reduced-order dynamics matrix.
      real(wp),            allocatable, intent(out)    :: Bhat(:, :)
      !! Reduced-order input-to-state matrix.
      real(wp),            allocatable, intent(out)    :: Chat(:, :)
      !! Reduced-order state-to-output matrix.
      real(wp),            allocatable, intent(out)    :: D(:, :)
      !! Feed-through matrix
      class(abstract_lti_system_rdp),   intent(inout)  :: LTI
      !! Large-scale LTI to project
      class(abstract_vector_rdp),       intent(inout)  :: T(:)
      !! Balancing transformation

      call ROM_Petrov_Galerkin_Projection(Ahat, Bhat, Chat, D, LTI, T, T)

      return
   end subroutine ROM_Galerkin_Projection_rdp

   subroutine project_onto_common_basis_rdp(UTV, VpTV, U, V)
      !! Computes the common orthonormal basis of the space spanned by the union of the input Krylov bases 
      !! \( [ \mathbf{U}, \mathbf{V} ] \) by computing \( \mathbf{V_\perp} \) as an orthonormal basis of 
      !! \( \mathbf{V} \) lying in the orthogonal complement of \( \mathbf{U} \) given by
      !! \[
      !!    \mathbf{V_\perp}, R = \text{qr}( \mathbf{V} - \mathbf{U} \mathbf{U}^T \mathbf{V} )
      !! \[
      !!
      !! NOTE: The orthonormality of \( \mathbf{U} \) is assumed and not checked.
      !! 
      !! The output is
      !! \[
      !!     \mathbf{U}^T \mathbf{V}, \qquad \text{and }  \qquad \mathbf{V_perp}^T \mathbf{V}
      !!     \hat{\mathbf{D}} = \mathbf{D} .
      !! \]
      real(wp),                   allocatable, intent(out) :: UTV(:,:)
      real(wp),                   allocatable, intent(out) :: VpTV(:,:)
      class(abstract_vector_rdp),              intent(in)  :: U(:)
      class(abstract_vector_rdp),              intent(in)  :: V(:)

      ! internals
      class(abstract_vector_rdp),             allocatable  :: Vp(:)
      integer :: ru, rv, r, info

      ru = size(U)
      rv = size(V)
      r  = ru + rv

      allocate(Vp(rv), source=V) ! Vp = V
      allocate(UTV( ru,rv)); UTV  = 0.0_wp
      allocate(VpTV(rv,rv)); VpTV = 0.0_wp

      ! orthonormalize second basis against first
      call orthogonalize_against_basis(Vp, U, info, if_chk_orthonormal=.false., beta=UTV)
      call check_info(info, 'orthogonalize_against_basis', module=this_module, procedure='project_onto_common_basis_rdp')
      call orthonormalize_basis(Vp)
      call check_info(info, 'qr', module=this_module, procedure='project_onto_common_basis_rdp')

      ! compute inner product between second basis and its orthonormalized version
      call innerprod(VpTV, Vp, V)

      return
   end subroutine project_onto_common_basis_rdp

   real(dp) function increment_norm(X, U_lag, S_lag, ifnorm) result(inc_norm)
      !! This function computes the norm of the solution increment in a cheap way avoiding the
      !! construction of the full low-rank solutions.
      class(abstract_sym_low_rank_state_rdp)  :: X
      !! Low rank solution of current solution
      class(abstract_vector_rdp)              :: U_lag(:)
      !! Low-rank basis of lagged solution
      real(wp)                                :: S_lag(:,:)
      !! Coefficients of lagged solution
      logical, optional, intent(in) :: ifnorm
      logical                       :: ifnorm_
      !! Normalize solution by vector size?

      ! internals
      real(wp), dimension(:,:),                 allocatable :: D, V1, V2
      real(wp), dimension(:),                   allocatable :: svals       
      integer :: rk, rl

      ifnorm_ = optval(ifnorm, .true.)

      rk  = X%rk
      rl = size(U_lag)

      ! compute common basis
      call project_onto_common_basis_rdp(V1, V2, U_lag, X%U(:rk))

      ! project second low-rank state onto common basis and construct difference
      allocate(D(rk+rl,rk+rl)); D = 0.0_wp
      D(    :rl   ,      :rl   ) = S_lag - matmul(V1, matmul(X%S(:rk,:rk), transpose(V1)))
      D(rl+1:rl+rk,      :rl   ) =       - matmul(V2, matmul(X%S(:rk,:rk), transpose(V1)))
      D(    :rl   ,  rl+1:rl+rk) =       - matmul(V1, matmul(X%S(:rk,:rk), transpose(V2)))
      D(rl+1:rl+rk,  rl+1:rl+rk) =       - matmul(V2, matmul(X%S(:rk,:rk), transpose(V2)))

      ! compute Frobenius norm of difference
      inc_norm = sqrt(sum(svdvals(D))**2)
      if (ifnorm_) inc_norm = inc_norm/X%U(1)%get_size()

      return
   end function increment_norm

   real(dp) function low_rank_CALE_residual_norm(X, A, B, ifnorm) result(residual_norm)
      class(abstract_sym_low_rank_state_rdp) :: X
      !! Low-Rank factors of the solution.
      class(abstract_linop_rdp)              :: A
      !! Linear operator
      class(abstract_vector_rdp)             :: B(:)
      !! Low-Rank inhomogeneity.
      logical, optional                      :: ifnorm
      logical                                :: ifnorm_
      !! Normalize the norm by the vector size?
      ! internals
      integer :: i, rk, rkb, n, info
      class(abstract_vector_rdp), allocatable :: Q(:)
      real(dp), dimension(:,:), allocatable :: R, R_shuffle, sqrt_S
      ! optional arguments
      ifnorm_ = optval(ifnorm, .true.)

      rk  = X%rk
      rkb = size(B)
      n   = 2*rk + rkb
      allocate(Q(n), source=B(1)); call zero_basis(Q)
      allocate(R(n,n), R_shuffle(n,n)); R = 0.0_dp; R_shuffle = 0.0_dp

      ! fill the basis
      allocate(sqrt_S(rk,rk)); sqrt_S = 0.0_dp
      call sqrtm(X%S(:rk,:rk), sqrt_S, info)
      call check_info(info, 'sqrtm', module=this_module, procedure='low_rank_CALE_residual_norm')
      block
         class(abstract_vector_rdp), allocatable :: Xwrk(:)
         call linear_combination(Xwrk, X%U(:rk), sqrt_S)
         call copy(Q(rk+1:2*rk), Xwrk)
      end block
      do i = 1, rk
         call A%matvec(Q(rk+i), Q(i))
      end do
      call copy(Q(2*rk+1:), B(:))

      call qr(Q, R, info)
      call check_info(info, 'qr', module=this_module, procedure='low_rank_CALE_residual_norm')

      R_shuffle(:,      :  rk) = R(:,  rk+1:2*rk)
      R_shuffle(:,  rk+1:2*rk) = R(:,      :  rk)
      R_shuffle(:,2*rk+1:    ) = R(:,2*rk+1:    )

      residual_norm = norm2(matmul(R_shuffle, transpose(R)))
      if (ifnorm_) residual_norm = residual_norm/B(1)%get_size()
      
      return
   end function low_rank_CALE_residual_norm

   real(dp) function coefficient_matrix_norm(X, ifnorm) result(norm)
      !! This function computes the Frobenius norm of a low-rank approximation via an SVD of the (small) coefficient matrix
      class(abstract_sym_low_rank_state_rdp), intent(in) :: X
      !! Low rank solution of which to compute the norm
      logical, optional, intent(in) :: ifnorm
      logical                       :: ifnorm_
      !! Normalize the norm by the vector size?
      ifnorm_ = optval(ifnorm, .true.)
      norm = sqrt(sum(svdvals(X%S(:X%rk,:X%rk))**2))
      if (ifnorm_) norm = norm/X%U(1)%get_size()
      return
   end function coefficient_matrix_norm

   logical function is_converged(svals, svals_lag, opts) result(converged)
      !! This function checks the convergence of the solution based on the (relative) increment in the singular values
      real(wp)                   :: svals(:)
      real(wp)                   :: svals_lag(:)
      real(wp),      allocatable :: dsvals(:)
      type(dlra_opts)            :: opts
      ! internals
      integer :: i
      real(wp) :: norm, norm_lag, dnorm
      character*128 :: msg

      norm     = sqrt(sum(svals**2))
      norm_lag = sqrt(sum(svals_lag**2))

      allocate(dsvals(size(svals)))
      do i = 1, size(svals)
         dsvals(i) = abs(svals(i) - svals_lag(i))
      end do

      dnorm    = sqrt(sum(dsvals**2))

      if (opts%relative_inc) dnorm = dnorm/norm

      converged = .false.

      write(msg,'(A,3(E15.7,1X))') 'svals lag inc_norm: ', norm, norm_lag, dnorm
      call logger%log_message(msg, module=this_module, procedure='DLRA convergence check')
      if (dnorm < opts%inc_tol) converged = .true.

      return
   end function is_converged

   subroutine check_options(chkstep, iostep, tau, X, opts)
      integer,                                 intent(out)   :: chkstep 
      integer,                                 intent(out)   :: iostep 
      real(wp),                                intent(in)    :: tau
      class(abstract_sym_low_rank_state_rdp),  intent(inout) :: X
      type(dlra_opts),                         intent(inout) :: opts

      ! internal
      character(len=128) :: msg
      type(dlra_opts) :: opts_default
      opts_default = dlra_opts()
      !
      ! CONVERGENCE CHECK
      !
      if (opts%chkctrl_time) then
         if (opts%chktime <= 0.0_wp) then
            opts%chktime = opts_default%chktime
            write(msg,'(A,E12.5,A)') 'Invalid chktime. Reset to default (',  opts%chktime,')'
            call logger%log_warning(msg, module=this_module, procedure='DLRA_check_options')
         end if
         chkstep = max(1, NINT(opts%chktime/tau))
         write(msg,'(A,E12.5,A,I0,A)') 'Convergence check every ', opts%chktime, ' time units (', chkstep, ' steps)'
         call logger%log_information(msg, module=this_module, procedure='DLRA_check_options')
      else
         if (opts%chkstep <= 0) then
            opts%chkstep = opts_default%chkstep
            write(msg,'(A,I0,A)') "Invalid chktime. Reset to default (",  opts%chkstep,")"
            call logger%log_warning(msg, module=this_module, procedure='DLRA_check_options')
         end if
         chkstep = opts%chkstep
         write(msg,'(A,I0,A)') 'Convergence check every ', chkstep, ' steps (based on steps).'
         call logger%log_information(msg, module=this_module, procedure='DLRA_check_options')
      end if
      !
      ! RUNTIME OUTPUT CALLBACK
      !
      if (opts%ifIO) then ! callback activated
         if (.not. associated(X%outpost)) then
            opts%ifIO = .false.
            write(msg,'(A,E12.5,A)') 'No outposting routine provided. Runtime output will be deactivated.'
            call logger%log_warning(msg, module=this_module, procedure='DLRA_check_options')
         end if
         if (opts%ioctrl_time) then
            if (opts%iotime <= 0.0_wp) then
               opts%iotime = opts_default%iotime
               write(msg,'(A,E12.5,A)') 'Invalid iotime. Reset to default (',  opts%iotime,')'
               call logger%log_warning(msg, module=this_module, procedure='DLRA_check_options')
            end if
            iostep = max(1, NINT(opts%iotime/tau))
            write(msg,'(A,E12.5,A,I0,A)') 'Output every ', opts%iotime, ' time units (', iostep, ' steps)'
            call logger%log_information(msg, module=this_module, procedure='DLRA_check_options')
         else
            if (opts%iostep <= 0) then
               opts%iostep = opts_default%iostep
               write(msg,'(A,I0,A)') "Invalid iotime. Reset to default (",  opts%iostep,")"
               call logger%log_warning(msg, module=this_module, procedure='DLRA_check_options')
            end if
            iostep = opts%iostep
            write(msg,'(A,I0,A)') 'Output every ', iostep, ' steps (based on steps).'
            call logger%log_information(msg, module=this_module, procedure='DLRA_check_options')
         end if
      else
         iostep = 0
         call logger%log_information('No runtime output.', module=this_module, procedure='DLRA_check_options')
      end if
      return
   end subroutine check_options

   subroutine write_logfile_headers(n0)
      integer, intent(in) :: n0
      ! internals
      integer :: i
      ! SVD absolute
      open (1234, file=logfile_SVD_abs, status='replace', action='write')
      write (1234, '(A8,2(A15,1X),A4)', ADVANCE='NO') 'istep', 'time', 'lag', 'rk'
      do i = 1, n0
         write (1234, '(A13,I2.2,1X)', ADVANCE='NO') 's', i
      end do
      write (1234, *) ''; close (1234)
      ! dSVD relative
      open (1234, file=logfile_SVD_rel, status='replace', action='write')
      write (1234, '(A8,2(A15,1X),A4)', ADVANCE='NO') 'istep', 'time', 'lag', 'rk'
      do i = 1, n0
         write (1234, '(A13,I2.2,1X)', ADVANCE='NO') 'ds', i
      end do
      write (1234, *) ''; close (1234)
      return
   end subroutine write_logfile_headers

   subroutine stamp_logfiles(X, lag, svals, dsvals)
      class(abstract_sym_low_rank_state_rdp),  intent(in) :: X
      real(dp), intent(in) :: lag
      real(dp), dimension(:), intent(in) :: svals
      real(dp), dimension(:), intent(in) :: dsvals
      ! SVD absolute
      open (1234, file=logfile_SVD_abs, status='old', action='write', position='append')
      write (1234, '(I8,2(1X,F15.9),I4)', ADVANCE='NO') X%step, X%time, lag, X%rk
      write (1234, '(*(1X,F15.9))') svals
      close (1234)
      ! dSVD relative
      open (1234, file=logfile_SVD_rel, status='old', action='write', position='append')
      write (1234, '(I8,2(1X,F15.9),I4)', ADVANCE='NO') X%step, X%time, lag, X%rk
      write (1234, '(*(1X,F15.9))') dsvals
      close (1234)
      return
   end subroutine stamp_logfiles

   subroutine chk_opts(opts)

      type(dlra_opts), intent(inout) :: opts

      ! internal
      character(len=128) :: msg
      type(dlra_opts) :: opts_default

      opts_default = dlra_opts()

      ! mode
      if ( opts%mode > 2 ) then
         opts%mode = 2
         write(msg, *) "Time-integration order for the operator splitting of d > 2 &
                      & requires adjoint solves and is not implemented. Resetting torder = 2." 
         if (io_rank()) call logger%log_warning(trim(msg), module=this_module, procedure='DLRA chk_opts')
      else if ( opts%mode < 1 ) then
         write(msg, '(A,I2)') "Invalid time-integration order specified: ", opts%mode
         call stop_error(trim(msg), module=this_module, procedure='DLRA chk_opts')
      endif

      ! chkctrl -- chkstep
      if (opts%chkctrl_time) then
         if (opts%chktime <= 0.0_wp) then
            opts%chktime = opts_default%chktime
            write(msg, '(A,F0.2,A,F0.2,A)') "Invalid chktime ( ", opts%chktime, " ). Reset to default ( ",  opts%chktime," )"
            if (io_rank()) call logger%log_warning(trim(msg), module=this_module, procedure='DLRA chk_opts')
         end if
      else
         if (opts%chkstep <= 0) then
            opts%chkstep = opts_default%chkstep
            write(msg, '(A,F0.2,A,I4,A)') "Invalid chktime ( ", opts%chktime, " ). Reset to default ( ",  opts%chkstep," )"
            if (io_rank()) call logger%log_message(trim(msg), module=this_module, procedure='DLRA chk_opts')
         end if
      end if

      ! initctrl --> ninit
      if (opts%initctrl_step) then
         if (opts%ninit <= 0) then
            opts%ninit = opts_default%ninit
            write(msg, '(A,I4,A,I4,A)') "Invalid ninit ( ", opts%ninit, " ). Reset to default ( ",  opts%ninit," )"
            if (io_rank()) call logger%log_warning(trim(msg), module=this_module, procedure='DLRA chk_opts')
         end if 
      else
         if (opts%tinit <= 0.0_wp) then
            opts%tinit = opts_default%tinit
            write(msg, '(A,F0.2,A,F0.2,A)') "Invalid tinit ( ", opts%tinit, " ). Reset to default ( ",  opts%tinit," )"
            if (io_rank()) call logger%log_warning(trim(msg), module=this_module, procedure='DLRA chk_opts')
         end if
      end if
      return
   end subroutine chk_opts

   subroutine random_low_rank_state_rdp(U, S, V)
      class(abstract_vector_rdp),           intent(inout) :: U(:)
      real(dp),                             intent(inout) :: S(:,:)
      class(abstract_vector_rdp), optional, intent(inout) :: V(:)

      ! internals
      integer :: i, rk
      real(dp), dimension(:,:), allocatable :: mu, var

      rk = size(S, 1)
      call assert_shape(S, [rk, rk], 'random_low_rank_state', 'S')
      if (size(U) /= rk) call stop_error('Input basis U and coefficient matrix S have incompatible sizes', &
                                          & module=this_module, procedure='random_low_rank_state_rdp')

      allocate(mu(rk,rk), var(rk,rk))
      mu  = zero_rdp
      var = one_rdp
      S = normal(mu, var)
      
      call zero_basis(U)
      do i = 1, size(U)
         call U(i)%rand(.false.)
      end do
      call orthonormalize_basis(U)

      if (present(V)) then
         if (size(V) /= rk) call stop_error('Input basis V and coefficient matrix S have incompatible sizes', &
                                          & module=this_module, procedure='random_low_rank_state_rdp')
         call zero_basis(V)
         do i = 1, size(V)
            call V(i)%rand(.false.)
         end do                    
         call orthonormalize_basis(V)
      else
         ! symmetric
         S = 0.5*(S + transpose(S))
      end if

   end subroutine random_low_rank_state_rdp
   
end module LightROM_Utils