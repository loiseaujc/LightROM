module Ginzburg_Landau_Utils
   ! Standard Library.
   use stdlib_math, only : linspace
   use stdlib_optval, only : optval
   use stdlib_linalg, only : eye, diag, svd
   use stdlib_io_npy, only : save_npy, load_npy
   !use fortime
   ! LightKrylov for linear algebra.
   use LightKrylov
   use LightKrylov, only : wp => dp
   use LightKrylov_AbstractVectors
   use LightKrylov_Utils, only : assert_shape
   ! LightROM
   use LightROM_AbstractLTIsystems
   use LightROM_Utils
   ! Lyapunov Solver
   use LightROM_LyapunovSolvers
   use LightROM_LyapunovUtils
   ! Riccati Solver
   use LightROM_RiccatiSolvers
   use LightROM_RiccatiUtils
   ! Ginzburg Landau
   use Ginzburg_Landau_Base
   use Ginzburg_Landau_Operators
   use Ginzburg_Landau_RK_Lyapunov

   implicit none

   private :: this_module
   ! mesh construction
   public  :: initialize_parameters
   ! utilities for state_vectors
   public  :: set_state, get_state, init_rand, reconstruct_solution
   ! initial conditions
   public  :: generate_random_initial_condition
   ! logfiles
   public  :: stamp_logfile_header
   ! misc
   public  :: CALE, CARE
   ! IO
   public  :: load_data, save_data

   character*128, parameter :: this_module = 'Ginzburg_Landau_Utils'

contains

   !--------------------------------------------------------------
   !-----     CONSTRUCT THE MESH AND PHYSICAL PARAMETERS     -----
   !--------------------------------------------------------------

   subroutine initialize_parameters()
      implicit none
      ! Mesh array.
      real(wp), allocatable :: x(:)
      real(wp)              :: x2(1:2*nx)
      real(wp), allocatable :: mat(:,:), matW(:,:)
      integer               :: i

      ! Construct mesh.
      x = linspace(-L/2, L/2, nx+2)
      dx = x(2)-x(1)
      
      ! Construct mu(x)
      mu(:) = (mu_0 - c_mu**2) + (mu_2 / 2.0_wp) * x(2:nx+1)**2

      ! Define integration weights
      weight          = dx
      weight_mat      = eye(N)*dx
      inv_weight_mat  = eye(N)*1/dx
      weight_flat     = dx

      ! Construct B & C
      ! B = [ [ Br, -Bi ], [ Bi, Br ] ]
      ! B = [ [ Cr, -Ci ], [ Ci, Cr ] ]
      ! where Bi = Ci = 0

      ! actuator is a Guassian centered just upstream of branch I
      ! column 1
      x2       = 0.0_wp
      x2(1:nx) = x(2:nx+1)
      B(1)%state = exp(-((x2 - x_b)/s_b)**2)!*sqrt(weight)
      ! column 2
      x2            = 0.0_wp
      x2(nx+1:2*nx) = x(2:nx+1)
      B(2)%state = exp(-((x2 - x_b)/s_b)**2)!*sqrt(weight)

      ! the sensor is a Gaussian centered at branch II
      ! column 1
      x2       = 0.0_wp
      x2(1:nx) = x(2:nx+1)
      CT(1)%state = exp(-((x2 - x_c)/s_c)**2) !/sqrt(weight)
      ! column 2
      x2            = 0.0_wp
      x2(nx+1:2*nx) = x(2:nx+1)
      CT(2)%state = exp(-((x2 - x_c)/s_c)**2) !/sqrt(weight)

      ! RK lyap & riccati
      Qc   = eye(rk_c)
      Rinv = eye(rk_b)
      allocate(mat(N, rk_b), matW(N, rk_b))
      call get_state(mat(:,1:rk_b), B(1:rk_b))
      matW = matmul(mat, weight_mat(:rk_b,:rk_b)) ! incorporate weights
      BBTW = matmul(mat, transpose(matW))
      BBTW_flat = reshape(BBTW, [N**2])
      BRinvBTW_mat  = matmul(mat, matmul(Rinv, transpose(matW)))
      deallocate(mat, matW)
      allocate(mat(N, rk_c), matW(N, rk_c))
      call get_state(mat(:,1:rk_c), CT(1:rk_c))
      matW = matmul(mat, inv_weight_mat(:rk_c,:rk_c)) ! incorporate weights
      CTCWinv_flat(1:N**2)   = reshape(matmul(mat, transpose(matW)), shape(CTCWinv_flat))
      CTQcCWinv_mat(1:N,1:N) =  matmul(mat, matmul(Qc, transpose(matW)))

      return
   end subroutine initialize_parameters

   !--------------------------------------------------------------------
   !-----     UTILITIES FOR STATE_VECTOR AND STATE MATRIX TYPES    -----
   !--------------------------------------------------------------------

   subroutine get_state(mat_out, state_in)
      !! Utility function to transfer data from a state vector to a real array
      real(wp),                   intent(out) :: mat_out(:,:)
      class(abstract_vector_rdp), intent(in)  :: state_in(:)
      ! internal variables
      integer :: k, kdim
      mat_out = 0.0_wp
      select type (state_in)
      type is (state_vector)
         kdim = size(state_in)
         call assert_shape(mat_out, [ N, kdim ], 'mat_out', this_module, 'get_state -> state_vector')
         do k = 1, kdim
            mat_out(:,k) = state_in(k)%state
         end do
      type is (state_matrix)
         call assert_shape(mat_out, [ N, N ], 'mat_out', this_module, 'get_state -> state_matrix')
         mat_out = reshape(state_in(1)%state, [ N, N ])
      end select
      return
   end subroutine get_state

   subroutine set_state(state_out, mat_in)
      !! Utility function to transfer data from a real array to a state vector
      class(abstract_vector_rdp), intent(out) :: state_out(:)
      real(wp),                   intent(in)  :: mat_in(:,:)
      ! internal variables
      integer       :: k, kdim
      select type (state_out)
      type is (state_vector)
         kdim = size(state_out)
         call assert_shape(mat_in, [ N, kdim ], 'mat_in', this_module, 'set_state -> state_vector')
         call zero_basis(state_out)
         do k = 1, kdim
            state_out(k)%state = mat_in(:,k)
         end do
      type is (state_matrix)
         call assert_shape(mat_in, [ N, N ], 'mat_in', this_module, 'set_state -> state_matrix')
         call zero_basis(state_out)
         state_out(1)%state = reshape(mat_in, shape(state_out(1)%state))
      end select
      return
   end subroutine set_state

   subroutine init_rand(state, ifnorm)
      !! Utility function to initialize a state vector with random data
      class(abstract_vector_rdp), intent(inout)  :: state(:)
      logical, optional,          intent(in)     :: ifnorm
      ! internal variables
      integer :: k, kdim
      logical :: normalize
      normalize = optval(ifnorm,.true.)
      select type (state)
      type is (state_vector)
         kdim = size(state)
         do k = 1, kdim
            call state(k)%rand(ifnorm = normalize)
         end do
      type is (state_matrix)
         kdim = size(state)
         do k = 1, kdim
            call state(k)%rand(ifnorm = normalize)
         end do
      end select
      return
   end subroutine init_rand

   subroutine reconstruct_solution(X, LR_X)
      real(wp),          intent(out) :: X(:,:)
      type(LR_state),    intent(in)  :: LR_X
      
      ! internals
      real(wp) :: wrk(N, LR_X%rk)

      call assert_shape(X, [ N, N ], 'X', this_module, 'reconstruct_solution')

      call get_state(wrk, LR_X%U(1:LR_X%rk))
      X = matmul(matmul(wrk, matmul(LR_X%S(1:LR_X%rk,1:LR_X%rk), transpose(wrk))), weight_mat)

      return
   end subroutine reconstruct_solution

   !------------------------------------
   !-----     INITIAL CONDIIONS    -----
   !------------------------------------

   subroutine generate_random_initial_condition(U, S, rk)
      class(state_vector),   intent(out) :: U(:)
      real(wp),              intent(out) :: S(:,:)
      integer,               intent(in)  :: rk
      ! internals
      class(state_vector),   allocatable :: Utmp(:)
      ! SVD
      real(wp)                           :: U_svd(rk,rk)
      real(wp)                           :: S_svd(rk)
      real(wp)                           :: V_svd(rk,rk)
      integer                            :: i, info
      character(len=128) :: msg

      if (size(U) < rk) then
         write(msg,'(A,I0)') 'Input krylov basis size incompatible with requested rank ', rk
         call stop_error(msg, module=this_module, procedure='generate_random_initial_condition')
         STOP 1
      else
         call zero_basis(U)
         do i = 1,rk
            call U(i)%rand(.false.)
         end do
      end if
      call assert_shape(S, [ rk,rk ], 'S', this_module, 'generate_random_initial_condition')
      S = 0.0_wp
      
      ! perform QR
      allocate(Utmp(rk), source=U(:rk))
      call qr(Utmp, S, info)
      call check_info(info, 'qr', module=this_module, procedure='generate_random_initial_condition')
      ! perform SVD
      call svd(S(:rk,:rk), S_svd, U_svd, V_svd)
      S(:rk,:rk) = diag(S_svd)
      block
         class(abstract_vector_rdp), allocatable :: Xwrk(:)
         call linear_combination(Xwrk, Utmp, U_svd)
         call copy_basis(U, Xwrk)
      end block
      write(msg,'(A,I0,A,I0,A)') 'size(U) = [ ', size(U),' ]: filling the first ', rk, ' columns with noise.'
      call logger%log_information(msg, module=this_module, procedure='generate_random_initial_condition')
      return
   end subroutine

   !-----------------------------
   !-----      LOGFILES     -----
   !-----------------------------

   subroutine stamp_logfile_header(iunit, problem, rk, tau, Tend, torder)
      integer,       intent(in) :: iunit
      character(*),  intent(in) :: problem
      integer,       intent(in) :: rk
      real(wp),      intent(in) :: tau
      real(wp),      intent(in) :: Tend
      integer,       intent(in) :: torder

      write(iunit,*) '-----------------------'
      write(iunit,*) '    GINZBURG LANDAU'
      write(iunit,*) '-----------------------'
      write(iunit,*) 'nu    = ', nu
      write(iunit,*) 'gamma = ', gamma
      write(iunit,*) 'mu_0  = ', mu_0
      write(iunit,*) 'c_mu  = ', c_mu
      write(iunit,*) 'mu_2  = ', mu_2
      write(iunit,*) '-----------------------'
      write(iunit,*) problem
      write(iunit,*) '-----------------------'
      write(iunit,*) 'nx    = ', nx
      write(iunit,*) 'rk_b  = ', rk_b
      write(iunit,*) 'x_b   = ', x_b
      write(iunit,*) 's_b   = ', s_b
      write(iunit,*) 'rk_c  = ', rk_c
      write(iunit,*) 'x_c   = ', x_c
      write(iunit,*) 's_c   = ', s_c
      write(iunit,*) '-----------------------'
      write(iunit,*) 'Time Integration: DLRA'
      write(iunit,*) '-----------------------'
      write(iunit,*) 'Tend   =', Tend
      write(iunit,*) 'torder =', torder
      write(iunit,*) 'tau    =', tau
      write(iunit,*) 'rk     =', rk
      write(iunit,*) '---------------------'
      write(iunit,*) '---------------------'
      return
   end subroutine stamp_logfile_header

   !-------------------------
   !-----      MISC     -----
   !-------------------------

   function CALE(X, Q, adjoint) result(res)
      
      ! solution
      real(wp)          :: X(N,N)
      ! inhomogeneity
      real(wp)          :: Q(N,N)
      ! adjoint
      logical, optional :: adjoint
      logical           :: adj
      ! residual
      real(wp)          :: res(N,N)

      ! internals
      real(wp), dimension(N**2) :: AX_flat, XAH_flat

      !> Deal with optional argument
      adj  = optval(adjoint,.false.)

      AX_flat = 0.0_wp; XAH_flat = 0.0_wp
      call GL_mat(AX_flat,  flat(X),             adjoint = adj, transpose = .false.)
      call GL_mat(XAH_flat, flat(transpose(X)),  adjoint = adj, transpose = .true. )

      ! construct Lyapunov equation
      res = reshape(AX_flat, [N,N]) + reshape(XAH_flat, [N,N]) + Q

   end function CALE

   function CARE(X, CTQcCW, BRinvBTW, adjoint) result(res)
      ! solution
      real(wp)          :: X(N,N)
      ! inhomogeneity
      real(wp)          :: CTQcCW(N,N)
      ! inhomogeneity
      real(wp)          :: BRinvBTW(N,N)
      ! adjoint
      logical, optional :: adjoint
      logical           :: adj
      ! residual
      real(wp)          :: res(N,N)

      ! internals
      real(wp), dimension(N**2) :: AX_flat, XAH_flat

      !> Deal with optional argument
      adj  = optval(adjoint,.false.)

      AX_flat = 0.0_wp; XAH_flat = 0.0_wp
      call GL_mat(AX_flat,  flat(X),             adjoint = adj, transpose = .false.)
      call GL_mat(XAH_flat, flat(transpose(X)),  adjoint = adj, transpose = .true. )
      
      ! construct Lyapunov equation
      res = reshape(AX_flat, [N,N]) + reshape(XAH_flat, [N,N]) + CTQcCW + matmul(X, matmul(BRinvBTW, X))

   end function CARE

   function flat(X) result(X_flat)
      real(wp) :: X(N,N)
      real(wp) :: X_flat(N**2)
      X_flat = reshape(X, [ N**2 ] )
   end function flat

   subroutine load_data(filename, U_load)
      character(len=*),      intent(in)  :: filename
      real(wp), allocatable, intent(out) :: U_load(:,:)
      ! internal
      logical :: existfile
      integer :: iostatus

      inquire(file=filename, exist=existfile)
      if (existfile) then
         call load_npy(trim(filename), U_load, iostatus)
         if (iostatus /= 0) call stop_error('Error loading file '//trim(filename), module=this_module, procedure='load_data')
      else
         call stop_error('Cannot find file '//trim(filename), module=this_module, procedure='load_data')
      end if
      call logger%log_message('Loaded data from '//trim(filename), module=this_module, procedure='load_data')
      return
   end subroutine load_data

   subroutine save_data(filename, data)
      character(len=*),      intent(in)  :: filename
      real(wp),              intent(in)  :: data(:,:)
      ! internal
      integer :: iostatus

      call save_npy(trim(filename), data, iostatus)
      if (iostatus /= 0) call stop_error('Error saving file '//trim(filename), module=this_module, procedure='save_data')
      call logger%log_message('Data saved to '//trim(filename), module=this_module, procedure='save_data')
      return
   end subroutine save_data

end module Ginzburg_Landau_Utils